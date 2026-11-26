-- New student accounts must use a BulSU student email (@ms.bulsu.edu.ph).
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.
--
-- * Accounts created before this file is first run keep working, whatever
--   their email: the rule only applies from `enforced_since` on.
-- * Only student accounts are checked. Professors created by the professor
--   dashboard are not affected.
-- * Two checks, so it can't be skipped from outside the app:
--     1. student sign-up (auth.users with student details in its sign-up
--        data) is refused for other emails;
--     2. an account can't become a student (public.users role 'student')
--        with another email, e.g. through "complete registration".
--
-- To change the domain later, update comptech_email_policy.domain.

create table if not exists public.comptech_email_policy (
  id boolean primary key default true check (id),
  domain text not null default 'ms.bulsu.edu.ph',
  enforced_since timestamptz not null default now()
);

-- First run only: the moment the rule starts. Re-running keeps it.
insert into public.comptech_email_policy (id) values (true)
on conflict (id) do nothing;

-- No policies: only the functions below read it.
alter table public.comptech_email_policy enable row level security;

create or replace function public.comptech_student_email_allowed(
  p_email text,
  p_created_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- No policy row means no rule.
  select coalesce((
    select p_created_at < p.enforced_since
        or lower(btrim(coalesce(p_email, ''))) like ('%@' || lower(p.domain))
    from public.comptech_email_policy p
    limit 1
  ), true);
$$;

revoke all on function public.comptech_student_email_allowed(text, timestamptz)
  from public, anon, authenticated;

-- 1. Student sign-up (the app sends student_number in the sign-up data).
create or replace function public.comptech_check_student_signup_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.raw_user_meta_data, '{}'::jsonb) ? 'student_number'
     and not public.comptech_student_email_allowed(new.email, coalesce(new.created_at, now())) then
    raise exception 'BULSU_EMAIL_REQUIRED'
      using hint = 'Student accounts must use an @ms.bulsu.edu.ph email.';
  end if;
  return new;
end;
$$;

revoke all on function public.comptech_check_student_signup_email()
  from public, anon, authenticated;

drop trigger if exists comptech_check_student_signup_email on auth.users;
create trigger comptech_check_student_signup_email
  before insert on auth.users
  for each row execute function public.comptech_check_student_signup_email();

-- 2. Becoming a student, however the users row is written.
create or replace function public.comptech_check_student_role_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_created timestamptz;
begin
  if lower(coalesce(new.role, '')) <> 'student' then
    return new;
  end if;
  if tg_op = 'UPDATE' and lower(coalesce(old.role, '')) = 'student' then
    return new;
  end if;

  select u.email, u.created_at into v_email, v_created
  from auth.users u where u.id = new.id;

  if found and not public.comptech_student_email_allowed(v_email, v_created) then
    raise exception 'BULSU_EMAIL_REQUIRED'
      using hint = 'Student accounts must use an @ms.bulsu.edu.ph email.';
  end if;
  return new;
end;
$$;

revoke all on function public.comptech_check_student_role_email()
  from public, anon, authenticated;

drop trigger if exists comptech_check_student_role_email on public.users;
create trigger comptech_check_student_role_email
  before insert or update of role on public.users
  for each row execute function public.comptech_check_student_role_email();
