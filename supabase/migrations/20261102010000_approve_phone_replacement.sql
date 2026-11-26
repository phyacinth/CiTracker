-- Approve a lost or replaced phone for NFC attendance.
--
-- The server allows a second phone only when an approval names the student's
-- current phone and the new phone's exact code (key fingerprint). When the new
-- phone registers, the server retires the old phone, activates the new one and
-- marks the approval as used, so each approval works once, for one phone.
--
-- Steps:
--   1. On the new phone, the student opens NFC Attendance > Phone Setup and
--      taps the NFC logo three times. The app shows "Replacement approval
--      needed" and a phone code under Registration details (Copy phone code).
--   2. The student sends that code to a professor or admin.
--   3. The admin runs, in the Supabase SQL Editor:
--        select public.comptech_approve_phone_replacement(
--          'student@ms.bulsu.edu.ph', '<phone code>', 'Lost phone', 'Your name');
--   4. Within 24 hours, the student taps the NFC logo three times again.
--
-- Run this whole file once in the SQL Editor to install the command. It is
-- safe to run again. Only the SQL Editor (admins) can use it; the app cannot.

create or replace function public.comptech_approve_phone_replacement(
  p_student_email text,
  p_new_phone_code text,
  p_reason text default 'Lost phone',
  p_approved_by text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := lower(btrim(coalesce(p_new_phone_code, '')));
  v_student uuid;
  v_name text;
  v_active uuid;
  v_id uuid := gen_random_uuid();
  v_expires timestamptz := now() + interval '24 hours';
begin
  if v_code !~ '^[0-9a-f]{64}$' then
    raise exception 'The phone code must be the 64-character code from Registration details (0-9 and a-f).';
  end if;

  select u.id, u.full_name into v_student, v_name
  from public.users u
  where lower(u.email) = lower(btrim(p_student_email)) and u.role = 'student';
  if not found then
    raise exception 'No student account found with the email %.', p_student_email;
  end if;

  select c.id into v_active
  from public.student_nfc_phone_credentials c
  where c.student_id = v_student and c.status = 'active';
  if not found then
    raise exception 'This student has no active registered phone, so no replacement is needed. They can register the phone normally.';
  end if;

  if exists (select 1 from public.student_nfc_phone_credentials c where c.key_fingerprint = v_code) then
    raise exception 'That phone code is already registered. Check that the student copied the code from the new phone.';
  end if;

  insert into public.nfc_phone_replacement_approvals
    (id, student_id, old_credential_id, new_key_fingerprint, reason, approved_by, created_at, expires_at)
  values
    (v_id, v_student, v_active, v_code,
     coalesce(nullif(btrim(p_reason), ''), 'Lost phone'),
     coalesce(nullif(btrim(p_approved_by), ''), 'admin'),
     now(), v_expires);

  return jsonb_build_object(
    'approved', true,
    'student', coalesce(v_name, p_student_email),
    'expires_at', v_expires,
    'next_step', 'Ask the student to tap the NFC logo three times in Phone Setup within 24 hours.'
  );
end;
$$;

revoke all on function public.comptech_approve_phone_replacement(text, text, text, text)
  from public, anon, authenticated;
