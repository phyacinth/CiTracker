-- Student check-in location for QR and NFC attendance, saved on the
-- attendance row.
--
-- Run this whole file in the Supabase SQL Editor after
-- 20261101000000_student_qr_attendance.sql. It is safe to run again.
--
-- Do not re-run 20261101000000 after this file: it would recreate the old
-- 3-argument submit function next to this one, and PostgREST could no longer
-- tell which one a 3-argument call means. Running this file again fixes it.
--
-- New columns on `attendance` (the professor dashboard already reads this
-- table, so professors see them with their existing access):
--   check_in_location       on campus: campus_name from comptech_campus_settings;
--                           otherwise the phone's area name, e.g.
--                           "Guinhawa, Malolos, Bulacan"
--   check_in_latitude/longitude, check_in_accuracy_m   the GPS reading
--   check_in_distance_m     metres from campus, computed by the database
--   check_in_on_campus      within the radius, accurate enough, not a mock location
--   check_in_mock_location  the phone reported a fake-GPS app
-- All are null when the phone sent no location.

-- An earlier version of this file kept locations in their own table.
drop table if exists public.comptech_attendance_locations;

alter table public.attendance
  add column if not exists check_in_location text,
  add column if not exists check_in_latitude double precision,
  add column if not exists check_in_longitude double precision,
  add column if not exists check_in_accuracy_m real,
  add column if not exists check_in_distance_m double precision,
  add column if not exists check_in_on_campus boolean,
  add column if not exists check_in_mock_location boolean;

-- One row: the building students must be near when they scan.
--   latitude/longitude  the building (not the middle of the whole campus)
--   radius_m            how far from that point still counts
--   max_accuracy_m      readings less accurate than this are not trusted;
--                       null turns the limit off
--   campus_name         saved as check_in_location for on-campus scans
-- Until it is filled in, check_in_distance_m and check_in_on_campus stay null.
-- Set or change it with:
--   insert into public.comptech_campus_settings
--     (latitude, longitude, radius_m, max_accuracy_m, campus_name)
--   values (<latitude>, <longitude>, 100, 100, '<name>')
--   on conflict (id) do update set latitude = excluded.latitude,
--     longitude = excluded.longitude, radius_m = excluded.radius_m,
--     max_accuracy_m = excluded.max_accuracy_m,
--     campus_name = excluded.campus_name, updated_at = now();
create table if not exists public.comptech_campus_settings (
  id boolean primary key default true check (id),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  radius_m real not null check (radius_m > 0),
  max_accuracy_m real default 100 check (max_accuracy_m > 0),
  campus_name text,
  updated_at timestamptz not null default now()
);

alter table public.comptech_campus_settings
  add column if not exists max_accuracy_m real default 100
    check (max_accuracy_m > 0),
  add column if not exists campus_name text;

-- No policies: only the security-definer functions below read it.
alter table public.comptech_campus_settings enable row level security;

-- Shared by QR and NFC check-ins so both judge "on campus" the same way.
-- Distance is worked out here, not on the phone, so the app can't send its
-- own "on campus" answer. All outputs are null until campus settings exist.
create or replace function public.comptech_campus_check(
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m real,
  p_is_mocked boolean,
  out distance_m double precision,
  out on_campus boolean,
  out campus_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_campus public.comptech_campus_settings%rowtype;
begin
  select * into v_campus from public.comptech_campus_settings limit 1;
  if not found then
    return;
  end if;

  distance_m := 2 * 6371000 * asin(least(1, sqrt(
    power(sin(radians(p_latitude - v_campus.latitude) / 2), 2)
    + cos(radians(v_campus.latitude)) * cos(radians(p_latitude))
      * power(sin(radians(p_longitude - v_campus.longitude) / 2), 2)
  )));
  -- Trusted only when close enough, accurate enough and not fake GPS.
  on_campus := distance_m <= v_campus.radius_m
    and not coalesce(p_is_mocked, false)
    and (v_campus.max_accuracy_m is null
         or coalesce(p_accuracy_m <= v_campus.max_accuracy_m, false));
  campus_name := nullif(btrim(v_campus.campus_name), '');
end;
$fn$;

-- Internal: only the check-in functions call it.
revoke all on function public.comptech_campus_check(double precision, double precision, real, boolean)
  from public, anon, authenticated;

-- Same checks as 20261101000000, plus optional location arguments. The
-- defaults keep older app builds (3 arguments) working.
drop function if exists public.comptech_student_submit_qr_attendance(uuid, uuid, text);
drop function if exists public.comptech_student_submit_qr_attendance(uuid, uuid, text, double precision, double precision, real, boolean, timestamptz);
drop function if exists public.comptech_student_submit_qr_attendance(uuid, uuid, text, double precision, double precision, real, boolean, text);

create function public.comptech_student_submit_qr_attendance(
  p_class_id uuid,
  p_session_id uuid,
  p_token text,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_accuracy_m real default null,
  p_is_mocked boolean default false,
  p_place_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id uuid := auth.uid();
  v_now timestamptz := now();
  v_grace interval := interval '15 minutes'; -- same as the professor QR function
  v_session public.attendance_sessions%rowtype;
  v_token public.attendance_qr_tokens%rowtype;
  v_has_location boolean := coalesce(
    p_latitude between -90 and 90 and p_longitude between -180 and 180, false);
  v_distance double precision;
  v_on_campus boolean;
  v_campus_name text;
begin
  if v_student_id is null then
    raise exception 'SIGN_IN_REQUIRED';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = v_student_id and u.role = 'student'
  ) then
    raise exception 'STUDENT_REQUIRED';
  end if;

  if not exists (
    select 1 from public.users u
    where u.id = v_student_id and nullif(btrim(u.student_number), '') is not null
  ) then
    raise exception 'PROFILE_REQUIRED';
  end if;

  if p_class_id is null or p_session_id is null
     or p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_REQUEST';
  end if;

  if not exists (
    select 1 from public.class_students cs
    where cs.class_id = p_class_id and cs.student_id = v_student_id
  ) then
    raise exception 'NOT_ENROLLED';
  end if;

  select * into v_session
  from public.attendance_sessions s
  where s.id = p_session_id and s.class_id = p_class_id;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if exists (
    select 1 from public.attendance a
    where a.session_id = p_session_id and a.student_id = v_student_id
  ) then
    return public.comptech_student_qr_attendance_status(p_class_id, p_session_id)
      || jsonb_build_object('already_recorded', true);
  end if;

  if v_session.ended_at is not null
     or lower(coalesce(v_session.status, '')) <> 'active' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

  if v_session.started_at is null then
    raise exception 'SESSION_POLICY_REQUIRED';
  end if;

  if v_now >= v_session.started_at + v_grace then
    raise exception 'GRACE_PERIOD_ENDED';
  end if;

  select * into v_token
  from public.attendance_qr_tokens t
  where t.session_id = p_session_id
    and (t.class_id is null or t.class_id = p_class_id)
    and t.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  order by t.created_at desc
  limit 1;

  if not found or v_token.revoked_at is not null then
    raise exception 'QR_INVALID_OR_REPLACED';
  end if;

  if v_token.expires_at <= v_now then
    raise exception 'QR_EXPIRED';
  end if;

  if v_has_location then
    select c.distance_m, c.on_campus, c.campus_name
      into v_distance, v_on_campus, v_campus_name
    from public.comptech_campus_check(
      p_latitude, p_longitude, p_accuracy_m, p_is_mocked) c;
  end if;

  -- Student history reads `attendance`; `attendance_records` keeps the method.
  -- Location is optional: a student without GPS still gets attendance.
  insert into public.attendance (
    session_id, student_id, status, check_in_time,
    check_in_location, check_in_latitude, check_in_longitude,
    check_in_accuracy_m, check_in_distance_m, check_in_on_campus,
    check_in_mock_location
  )
  values (
    p_session_id, v_student_id, 'present', v_now,
    -- On campus: the official name from settings, never text from the phone.
    case
      when v_on_campus and v_campus_name is not null then v_campus_name
      when v_has_location then left(nullif(btrim(p_place_name), ''), 200)
    end,
    case when v_has_location then p_latitude end,
    case when v_has_location then p_longitude end,
    case when v_has_location and p_accuracy_m >= 0 then p_accuracy_m end,
    v_distance,
    v_on_campus,
    case when v_has_location then coalesce(p_is_mocked, false) end
  )
  on conflict (session_id, student_id) do nothing;

  insert into public.attendance_records
    (session_id, class_id, student_id, status, method, checked_in_at, updated_at)
  values
    (p_session_id, p_class_id, v_student_id, 'present', 'qr', v_now, v_now)
  on conflict (session_id, student_id) do nothing;

  return public.comptech_student_qr_attendance_status(p_class_id, p_session_id);
end;
$$;

revoke all on function public.comptech_student_submit_qr_attendance(uuid, uuid, text, double precision, double precision, real, boolean, text)
  from public, anon;
grant execute on function public.comptech_student_submit_qr_attendance(uuid, uuid, text, double precision, double precision, real, boolean, text)
  to authenticated;

-- NFC check-ins are saved by the `nfc-attendance` Edge Function, which this
-- repo does not own, so the app sends the location right after the check-in
-- succeeds. Only the caller's own check-in from the last 5 minutes that has
-- no location yet is accepted, so a location can't be attached to an old
-- check-in later from somewhere else. p_session_id null means the newest one
-- (phone tap: the student's phone doesn't know the session).
create or replace function public.comptech_student_record_check_in_location(
  p_session_id uuid default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_accuracy_m real default null,
  p_is_mocked boolean default false,
  p_place_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id uuid := auth.uid();
  v_now timestamptz := now();
  v_attendance_id public.attendance.id%type;
  v_distance double precision;
  v_on_campus boolean;
  v_campus_name text;
begin
  if v_student_id is null then
    raise exception 'SIGN_IN_REQUIRED';
  end if;

  if not coalesce(
    p_latitude between -90 and 90 and p_longitude between -180 and 180, false) then
    raise exception 'INVALID_REQUEST';
  end if;

  select a.id into v_attendance_id
  from public.attendance a
  where a.student_id = v_student_id
    and (p_session_id is null or a.session_id = p_session_id)
    and a.check_in_latitude is null
    and a.check_in_time between v_now - interval '5 minutes' and v_now
  order by a.check_in_time desc
  limit 1
  for update;

  if not found then
    raise exception 'CHECK_IN_NOT_FOUND';
  end if;

  select c.distance_m, c.on_campus, c.campus_name
    into v_distance, v_on_campus, v_campus_name
  from public.comptech_campus_check(
    p_latitude, p_longitude, p_accuracy_m, p_is_mocked) c;

  update public.attendance a set
    -- On campus: the official name from settings, never text from the phone.
    check_in_location = case
      when v_on_campus and v_campus_name is not null then v_campus_name
      else left(nullif(btrim(p_place_name), ''), 200)
    end,
    check_in_latitude = p_latitude,
    check_in_longitude = p_longitude,
    check_in_accuracy_m = case when p_accuracy_m >= 0 then p_accuracy_m end,
    check_in_distance_m = v_distance,
    check_in_on_campus = v_on_campus,
    check_in_mock_location = coalesce(p_is_mocked, false)
  where a.id = v_attendance_id;

  return jsonb_build_object(
    'check_in_on_campus', v_on_campus,
    'check_in_distance_m', v_distance
  );
end;
$$;

revoke all on function public.comptech_student_record_check_in_location(uuid, double precision, double precision, real, boolean, text)
  from public, anon;
grant execute on function public.comptech_student_record_check_in_location(uuid, double precision, double precision, real, boolean, text)
  to authenticated;

-- The signed-in student's check-in locations for one class. Separate from
-- `student_get_attendance` (professor dashboard) so that function is untouched.
create or replace function public.comptech_student_attendance_locations(
  p_class_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'session_id', a.session_id,
    'check_in_time', a.check_in_time,
    'check_in_location', a.check_in_location,
    'check_in_latitude', a.check_in_latitude,
    'check_in_longitude', a.check_in_longitude,
    'check_in_accuracy_m', a.check_in_accuracy_m,
    'check_in_distance_m', a.check_in_distance_m,
    'check_in_on_campus', a.check_in_on_campus,
    'check_in_mock_location', a.check_in_mock_location
  )), '[]'::jsonb)
  from public.attendance a
  join public.attendance_sessions s on s.id = a.session_id
  where s.class_id = p_class_id
    and a.student_id = auth.uid();
$$;

revoke all on function public.comptech_student_attendance_locations(uuid)
  from public, anon;
grant execute on function public.comptech_student_attendance_locations(uuid)
  to authenticated;

notify pgrst, 'reload schema';
