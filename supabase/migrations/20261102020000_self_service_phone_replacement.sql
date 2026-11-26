-- Self-service phone replacement (no approval needed), with an on/off switch.
--
-- With v_self_service = true (below), a student whose phone was lost or
-- replaced registers the new phone with the hidden NFC-logo tap in Phone
-- Setup. The server records an approval automatically (approved_by =
-- 'self-service'), retires the old phone and activates the new one.
--
-- To require approvals again later: change v_self_service to false and run
-- this file again. Approvals are then created with
-- public.comptech_approve_phone_replacement (see the approve_phone_replacement
-- migration).
--
-- Only nfc_phone_registration_eligibility changes; everything else in phone
-- registration (signature checks, one active phone per account, keys can't be
-- shared between accounts, retired keys are never reactivated) is unchanged.
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.

-- Lets the app tell a first registration apart from a replacement, so the
-- visible Register This Phone button only appears the first time.
create or replace function public.comptech_my_phone_registered()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.student_nfc_phone_credentials c
    where c.student_id = auth.uid() and c.status = 'active'
  );
$$;

revoke all on function public.comptech_my_phone_registered() from public, anon;
grant execute on function public.comptech_my_phone_registered() to authenticated;

create or replace function public.nfc_phone_registration_eligibility(p_student uuid, p_fingerprint text)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  -- true: lost/replaced phones are re-registered without approval.
  -- false: an approval from comptech_approve_phone_replacement is required.
  v_self_service constant boolean := true;
  v_existing public.student_nfc_phone_credentials%rowtype;
  v_active public.student_nfc_phone_credentials%rowtype;
begin
  if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_PUBLIC_KEY';
  end if;
  if exists(select 1 from public.student_nfc_phone_credentials
      where key_fingerprint=p_fingerprint and student_id<>p_student) then
    raise exception 'KEY_ALREADY_REGISTERED';
  end if;
  if (select count(*) from public.student_nfc_phone_credentials
      where student_id=p_student and status='active') > 1 then
    raise exception 'CREDENTIAL_NOT_ELIGIBLE';
  end if;
  select * into v_existing from public.student_nfc_phone_credentials
    where student_id=p_student and key_fingerprint=p_fingerprint for update;
  if found then
    if v_existing.status='active' then return null; end if;
    if v_existing.status='pending' and not exists(
      select 1 from public.student_nfc_phone_credentials
      where student_id=p_student and id<>v_existing.id
    ) then return null; end if;
    -- Never reactivate a revoked/replaced or conflicting pending key.
    raise exception 'AUTHORIZED_PHONE_REPLACEMENT_REQUIRED';
  end if;
  if not exists(select 1 from public.student_nfc_phone_credentials where student_id=p_student) then
    return null;
  end if;
  select * into v_active from public.student_nfc_phone_credentials
    where student_id=p_student and status='active' for update;
  if not found then
    -- No active phone (old one revoked): self-service registers this one as new.
    if v_self_service then return null; end if;
    raise exception 'AUTHORIZED_PHONE_REPLACEMENT_REQUIRED';
  end if;
  perform id from public.nfc_phone_replacement_approvals
    where student_id=p_student and old_credential_id=v_active.id
      and new_key_fingerprint=p_fingerprint and consumed_at is null
      and expires_at>clock_timestamp() for update;
  if not found then
    if not v_self_service then
      raise exception 'AUTHORIZED_PHONE_REPLACEMENT_REQUIRED';
    end if;
    -- Record the replacement so registration completes exactly as an approved one.
    insert into public.nfc_phone_replacement_approvals
      (id, student_id, old_credential_id, new_key_fingerprint, reason, approved_by, created_at, expires_at)
    values
      (gen_random_uuid(), p_student, v_active.id, p_fingerprint,
       'Self-service phone replacement', 'self-service',
       clock_timestamp(), clock_timestamp() + interval '10 minutes');
  end if;
  return v_active.id;
end;
$function$;
