-- Offline attendance fallback: check-ins saved on a phone with no internet
-- and uploaded once it reconnects. Online attendance is unchanged.
--
-- Run this whole file in the Supabase SQL Editor after
-- 20261103020000_published_gradebook.sql. It is safe to run again.
-- Then deploy the Edge Function in supabase/functions/comptech-offline-attendance.
--
-- Three kinds of upload, all through that Edge Function, which first checks
-- the student's registered-phone signature (Postgres can't verify it):
--   QR scan       a student scanned the professor's QR with no internet
--   phone tap     the professor's scanner had no internet; it saved the
--                 student's signed tap and, optionally, its own location
--   location      a student's phone saved its location at an NFC tap and
--                 sends it later
-- The functions below are only callable by the Edge Function (service_role).
--
-- Rules, matching online attendance where possible:
--   * The QR code must have been valid at the scan time (even if replaced
--     since), within the first 15 minutes of the session.
--   * Phone taps must be within 10 minutes of the session start, like the
--     online NFC scanner.
--   * Uploads are accepted until the end of the same day (Philippine time).
--   * One check-in per student per session; an earlier check-in is never
--     replaced. Each upload ID is processed once; re-sending it returns the
--     first result.

alter table public.attendance
  add column if not exists check_in_method text,
  add column if not exists synced_at timestamptz,
  add column if not exists scanner_latitude double precision,
  add column if not exists scanner_longitude double precision,
  add column if not exists scanner_accuracy_m real,
  add column if not exists scanner_distance_m double precision,
  add column if not exists scanner_on_campus boolean;

-- One row per processed upload, so a re-sent upload returns the first result.
create table if not exists public.comptech_offline_uploads (
  upload_id uuid primary key,
  kind text not null check (kind in ('qr', 'phone_tap', 'location')),
  actor_id uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.comptech_offline_uploads enable row level security;
revoke all on public.comptech_offline_uploads from public, anon, authenticated;

-- QR scan saved offline by a student.
create or replace function public.comptech_offline_qr_checkin(
  p_student_id uuid,
  p_upload_id uuid,
  p_class_id uuid,
  p_session_id uuid,
  p_token text,
  p_scanned_at timestamptz,
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
  v_now timestamptz := now();
  v_result jsonb;
  v_code text;
  v_session public.attendance_sessions%rowtype;
  v_has_location boolean := coalesce(
    p_latitude between -90 and 90 and p_longitude between -180 and 180, false);
  v_distance double precision;
  v_on_campus boolean;
  v_campus_name text;
begin
  select u.result into v_result
  from public.comptech_offline_uploads u where u.upload_id = p_upload_id;
  if found then
    return v_result;
  end if;

  <<checks>>
  begin
    if not exists (
      select 1 from public.users u
      where u.id = p_student_id and u.role = 'student'
        and nullif(btrim(u.student_number), '') is not null
    ) then
      v_code := 'STUDENT_REQUIRED'; exit checks;
    end if;

    if not exists (
      select 1 from public.class_students cs
      where cs.class_id = p_class_id and cs.student_id = p_student_id
    ) then
      v_code := 'NOT_ENROLLED'; exit checks;
    end if;

    select * into v_session from public.attendance_sessions s
    where s.id = p_session_id and s.class_id = p_class_id;
    if not found or v_session.started_at is null then
      v_code := 'SESSION_NOT_FOUND'; exit checks;
    end if;

    if p_scanned_at is null or p_scanned_at > v_now + interval '2 minutes' then
      v_code := 'INVALID_TIME'; exit checks;
    end if;
    if (v_now at time zone 'Asia/Manila')::date
       <> (p_scanned_at at time zone 'Asia/Manila')::date then
      v_code := 'UPLOAD_TOO_LATE'; exit checks;
    end if;
    if p_scanned_at < v_session.started_at - interval '2 minutes'
       or (v_session.ended_at is not null
           and p_scanned_at > v_session.ended_at + interval '1 minute') then
      v_code := 'SESSION_NOT_ACTIVE'; exit checks;
    end if;
    if p_scanned_at >= v_session.started_at + interval '15 minutes' then
      v_code := 'GRACE_PERIOD_ENDED'; exit checks;
    end if;

    -- The code must have been on screen at the scan time; one minute of
    -- leeway covers the difference between the phones' clocks.
    if p_token is null or p_token !~ '^[0-9a-f]{64}$' or not exists (
      select 1 from public.attendance_qr_tokens t
      where t.session_id = p_session_id
        and (t.class_id is null or t.class_id = p_class_id)
        and t.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
        and t.created_at <= p_scanned_at + interval '1 minute'
        and t.expires_at >= p_scanned_at - interval '1 minute'
        and (t.revoked_at is null or t.revoked_at >= p_scanned_at - interval '1 minute')
    ) then
      v_code := 'QR_INVALID'; exit checks;
    end if;
  end;

  if v_code is not null then
    v_result := jsonb_build_object('status', 'rejected', 'code', v_code);
  elsif exists (
    select 1 from public.attendance a
    where a.session_id = p_session_id and a.student_id = p_student_id
  ) then
    v_result := jsonb_build_object('status', 'already_recorded');
  else
    if v_has_location then
      select c.distance_m, c.on_campus, c.campus_name
        into v_distance, v_on_campus, v_campus_name
      from public.comptech_campus_check(
        p_latitude, p_longitude, p_accuracy_m, p_is_mocked) c;
    end if;

    insert into public.attendance (
      session_id, student_id, status, check_in_time,
      check_in_method, synced_at,
      check_in_location, check_in_latitude, check_in_longitude,
      check_in_accuracy_m, check_in_distance_m, check_in_on_campus,
      check_in_mock_location
    )
    values (
      p_session_id, p_student_id, 'present', p_scanned_at,
      'qr_offline', v_now,
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

    -- attendance_records (professor dashboard) only allows nfc, qr and manual;
    -- the offline mark is kept in attendance.check_in_method.
    insert into public.attendance_records
      (session_id, class_id, student_id, status, method, checked_in_at, updated_at)
    values
      (p_session_id, p_class_id, p_student_id, 'present', 'qr', p_scanned_at, v_now)
    on conflict (session_id, student_id) do nothing;

    v_result := jsonb_build_object('status', 'recorded', 'check_in_time', p_scanned_at);
  end if;

  insert into public.comptech_offline_uploads (upload_id, kind, actor_id, result)
  values (p_upload_id, 'qr', p_student_id, v_result)
  on conflict (upload_id) do nothing;

  return v_result;
end;
$$;

-- Phone tap saved offline by the professor's scanner. The Edge Function has
-- already checked the student's signature against their registered phone.
-- A session opened while offline is created here on first upload.
create or replace function public.comptech_offline_phone_tap(
  p_professor_id uuid,
  p_upload_id uuid,
  p_student_id uuid,
  p_class_id uuid,
  p_session_id uuid,
  p_session_started_at timestamptz,
  p_tapped_at timestamptz,
  p_scanner_latitude double precision default null,
  p_scanner_longitude double precision default null,
  p_scanner_accuracy_m real default null,
  p_scanner_is_mocked boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_result jsonb;
  v_code text;
  v_session public.attendance_sessions%rowtype;
  v_has_location boolean := coalesce(
    p_scanner_latitude between -90 and 90
      and p_scanner_longitude between -180 and 180, false);
  v_distance double precision;
  v_on_campus boolean;
  v_campus_name text;
begin
  select u.result into v_result
  from public.comptech_offline_uploads u where u.upload_id = p_upload_id;
  if found then
    return v_result;
  end if;

  <<checks>>
  begin
    if not exists (
      select 1 from public.classes c
      where c.id = p_class_id and c.faculty_id = p_professor_id
    ) then
      v_code := 'CLASS_NOT_OWNED'; exit checks;
    end if;

    if not exists (
      select 1 from public.class_students cs
      where cs.class_id = p_class_id and cs.student_id = p_student_id
    ) then
      v_code := 'NOT_ENROLLED'; exit checks;
    end if;

    if p_tapped_at is null or p_tapped_at > v_now + interval '2 minutes' then
      v_code := 'INVALID_TIME'; exit checks;
    end if;
    if (v_now at time zone 'Asia/Manila')::date
       <> (p_tapped_at at time zone 'Asia/Manila')::date then
      v_code := 'UPLOAD_TOO_LATE'; exit checks;
    end if;

    select * into v_session from public.attendance_sessions s
    where s.id = p_session_id;
    if found then
      if v_session.class_id is distinct from p_class_id
         or v_session.started_at is null then
        v_code := 'SESSION_NOT_FOUND'; exit checks;
      end if;
    else
      -- Opened on the scanner while offline.
      if p_session_started_at is null
         or p_session_started_at > p_tapped_at + interval '2 minutes'
         or p_session_started_at < p_tapped_at - interval '12 hours' then
        v_code := 'SESSION_NOT_FOUND'; exit checks;
      end if;
      insert into public.attendance_sessions
        (id, class_id, started_by, started_at, ended_at, status)
      values
        (p_session_id, p_class_id, p_professor_id, p_session_started_at,
         p_tapped_at, 'ended')
      on conflict (id) do nothing;
      select * into v_session from public.attendance_sessions s
      where s.id = p_session_id;
    end if;

    if p_tapped_at < v_session.started_at - interval '2 minutes' then
      v_code := 'SESSION_NOT_ACTIVE'; exit checks;
    end if;
    if p_tapped_at >= v_session.started_at + interval '10 minutes' then
      v_code := 'GRACE_PERIOD_ENDED'; exit checks;
    end if;
  end;

  if v_code is not null then
    v_result := jsonb_build_object('status', 'rejected', 'code', v_code);
  elsif exists (
    select 1 from public.attendance a
    where a.session_id = p_session_id and a.student_id = p_student_id
  ) then
    v_result := jsonb_build_object('status', 'already_recorded');
  else
    if v_has_location then
      select c.distance_m, c.on_campus, c.campus_name
        into v_distance, v_on_campus, v_campus_name
      from public.comptech_campus_check(
        p_scanner_latitude, p_scanner_longitude,
        p_scanner_accuracy_m, p_scanner_is_mocked) c;
    end if;

    insert into public.attendance (
      session_id, student_id, status, check_in_time,
      check_in_method, synced_at,
      scanner_latitude, scanner_longitude, scanner_accuracy_m,
      scanner_distance_m, scanner_on_campus
    )
    values (
      p_session_id, p_student_id, 'present', p_tapped_at,
      'phone_tap_offline', v_now,
      case when v_has_location then p_scanner_latitude end,
      case when v_has_location then p_scanner_longitude end,
      case when v_has_location and p_scanner_accuracy_m >= 0 then p_scanner_accuracy_m end,
      v_distance,
      v_on_campus
    )
    on conflict (session_id, student_id) do nothing;

    -- attendance_records only allows nfc, qr and manual (see the QR function).
    insert into public.attendance_records
      (session_id, class_id, student_id, status, method, checked_in_at, updated_at)
    values
      (p_session_id, p_class_id, p_student_id, 'present', 'nfc', p_tapped_at, v_now)
    on conflict (session_id, student_id) do nothing;

    -- Keep an offline-opened session's end time at its latest tap.
    update public.attendance_sessions s
    set ended_at = greatest(s.ended_at, p_tapped_at)
    where s.id = p_session_id and s.status = 'ended' and s.started_by = p_professor_id;

    v_result := jsonb_build_object('status', 'recorded', 'check_in_time', p_tapped_at);
  end if;

  insert into public.comptech_offline_uploads (upload_id, kind, actor_id, result)
  values (p_upload_id, 'phone_tap', p_professor_id, v_result)
  on conflict (upload_id) do nothing;

  return v_result;
end;
$$;

-- A student's location from an NFC tap, sent later. It attaches to their
-- check-in within 2 minutes of the capture time that has no location yet.
-- If that check-in isn't uploaded yet (the professor was offline too), the
-- result is 'pending' and the phone tries again later.
create or replace function public.comptech_offline_attach_location(
  p_student_id uuid,
  p_upload_id uuid,
  p_captured_at timestamptz,
  p_latitude double precision,
  p_longitude double precision,
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
  v_now timestamptz := now();
  v_result jsonb;
  v_attendance_id public.attendance.id%type;
  v_distance double precision;
  v_on_campus boolean;
  v_campus_name text;
begin
  select u.result into v_result
  from public.comptech_offline_uploads u where u.upload_id = p_upload_id;
  if found then
    return v_result;
  end if;

  if p_captured_at is null or p_captured_at > v_now + interval '2 minutes'
     or not coalesce(
       p_latitude between -90 and 90 and p_longitude between -180 and 180, false) then
    v_result := jsonb_build_object('status', 'rejected', 'code', 'INVALID_REQUEST');
  elsif (v_now at time zone 'Asia/Manila')::date
        <> (p_captured_at at time zone 'Asia/Manila')::date then
    v_result := jsonb_build_object('status', 'rejected', 'code', 'UPLOAD_TOO_LATE');
  else
    select a.id into v_attendance_id
    from public.attendance a
    where a.student_id = p_student_id
      and a.check_in_latitude is null
      and a.check_in_time between p_captured_at - interval '2 minutes'
                              and p_captured_at + interval '2 minutes'
    order by abs(extract(epoch from a.check_in_time - p_captured_at))
    limit 1
    for update;

    if not found then
      -- Not final: the check-in may still be on the professor's phone.
      return jsonb_build_object('status', 'pending', 'code', 'CHECK_IN_NOT_FOUND');
    end if;

    select c.distance_m, c.on_campus, c.campus_name
      into v_distance, v_on_campus, v_campus_name
    from public.comptech_campus_check(
      p_latitude, p_longitude, p_accuracy_m, p_is_mocked) c;

    update public.attendance a set
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

    v_result := jsonb_build_object('status', 'recorded');
  end if;

  insert into public.comptech_offline_uploads (upload_id, kind, actor_id, result)
  values (p_upload_id, 'location', p_student_id, v_result)
  on conflict (upload_id) do nothing;

  return v_result;
end;
$$;

revoke all on function public.comptech_offline_qr_checkin(uuid, uuid, uuid, uuid, text, timestamptz, double precision, double precision, real, boolean, text)
  from public, anon, authenticated;
revoke all on function public.comptech_offline_phone_tap(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, double precision, double precision, real, boolean)
  from public, anon, authenticated;
revoke all on function public.comptech_offline_attach_location(uuid, uuid, timestamptz, double precision, double precision, real, boolean, text)
  from public, anon, authenticated;
grant execute on function public.comptech_offline_qr_checkin(uuid, uuid, uuid, uuid, text, timestamptz, double precision, double precision, real, boolean, text)
  to service_role;
grant execute on function public.comptech_offline_phone_tap(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, double precision, double precision, real, boolean)
  to service_role;
grant execute on function public.comptech_offline_attach_location(uuid, uuid, timestamptz, double precision, double precision, real, boolean, text)
  to service_role;

-- Student history: also return how the check-in was made and, for offline
-- phone taps, the professor scanner's location.
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
    'check_in_method', a.check_in_method,
    'synced_at', a.synced_at,
    'check_in_location', a.check_in_location,
    'check_in_latitude', a.check_in_latitude,
    'check_in_longitude', a.check_in_longitude,
    'check_in_accuracy_m', a.check_in_accuracy_m,
    'check_in_distance_m', a.check_in_distance_m,
    'check_in_on_campus', a.check_in_on_campus,
    'check_in_mock_location', a.check_in_mock_location,
    'scanner_latitude', a.scanner_latitude,
    'scanner_longitude', a.scanner_longitude,
    'scanner_accuracy_m', a.scanner_accuracy_m,
    'scanner_distance_m', a.scanner_distance_m,
    'scanner_on_campus', a.scanner_on_campus
  )), '[]'::jsonb)
  from public.attendance a
  join public.attendance_sessions s on s.id = a.session_id
  where s.class_id = p_class_id
    and a.student_id = auth.uid();
$$;

notify pgrst, 'reload schema';
