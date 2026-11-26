-- Student QR attendance check-in.
--
-- The professor dashboard owns the `qr-attendance` Edge Function and only
-- handles issuing QR codes there. Student check-in lives in these database
-- functions instead, so redeploying that Edge Function can't break it.
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.
--
-- Shared with the professor dashboard (if they change these, update this file):
--   attendance_sessions  (id, class_id, started_at, ended_at, status)
--   attendance_qr_tokens (session_id, class_id, token_hash = sha256 hex of the
--                         raw token, expires_at, revoked_at, created_at)
--   15-minute grace period after started_at

-- Returns the class subject/section and the caller's attendance for one
-- session, or attendance = null.
create or replace function public.comptech_student_qr_attendance_status(
  p_class_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id uuid := auth.uid();
  v_class public.classes%rowtype;
  v_attendance jsonb;
begin
  if v_student_id is null then
    raise exception 'SIGN_IN_REQUIRED';
  end if;

  if not exists (
    select 1 from public.class_students cs
    where cs.class_id = p_class_id and cs.student_id = v_student_id
  ) then
    raise exception 'NOT_ENROLLED';
  end if;

  select jsonb_build_object(
    'id', a.id,
    'student_id', a.student_id,
    'session_id', a.session_id,
    'status', a.status,
    'check_in_time', a.check_in_time
  )
  into v_attendance
  from public.attendance a
  join public.attendance_sessions s on s.id = a.session_id
  where a.session_id = p_session_id
    and a.student_id = v_student_id
    and s.class_id = p_class_id;

  select * into v_class from public.classes c where c.id = p_class_id;

  return jsonb_build_object(
    'class_id', p_class_id,
    'subject', v_class.subject,
    'section', v_class.section,
    'already_recorded', false,
    'attendance', v_attendance
  );
end;
$$;

-- Checks the scanned QR and records the caller as present.
-- Scanning again after a successful check-in returns the existing record.
create or replace function public.comptech_student_submit_qr_attendance(
  p_class_id uuid,
  p_session_id uuid,
  p_token text
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

  -- Student history reads `attendance`; `attendance_records` keeps the method.
  insert into public.attendance (session_id, student_id, status, check_in_time)
  values (p_session_id, v_student_id, 'present', v_now)
  on conflict (session_id, student_id) do nothing;

  insert into public.attendance_records
    (session_id, class_id, student_id, status, method, checked_in_at, updated_at)
  values
    (p_session_id, p_class_id, v_student_id, 'present', 'qr', v_now, v_now)
  on conflict (session_id, student_id) do nothing;

  return public.comptech_student_qr_attendance_status(p_class_id, p_session_id);
end;
$$;

revoke all on function public.comptech_student_qr_attendance_status(uuid, uuid)
  from public, anon;
grant execute on function public.comptech_student_qr_attendance_status(uuid, uuid)
  to authenticated;

revoke all on function public.comptech_student_submit_qr_attendance(uuid, uuid, text)
  from public, anon;
grant execute on function public.comptech_student_submit_qr_attendance(uuid, uuid, text)
  to authenticated;

notify pgrst, 'reload schema';
