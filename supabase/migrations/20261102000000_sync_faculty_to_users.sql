-- Keep public.users in step with public.faculty_profiles.
--
-- The professor dashboard saves new professors in faculty_profiles only. The
-- student app's login and the nfc-attendance function look professors up in
-- public.users, so new dashboard professors were refused by the Professor NFC
-- scanner ("This account has no completed application profile").
-- This adds the matching users row automatically.
--
-- Safe for both dashboards:
--   * It only adds a missing users row or fills in an empty role. It never
--     changes an existing role and never touches students.
--   * If a leftover users row of a deleted account (no login account,
--     student profile, classes, attendance or NFC cards) holds the
--     professor's email, its email is renamed to
--     orphaned-<id>@invalid.local so the professor's row can be added.
--   * If adding the users row fails for any reason, the professor dashboard's
--     own save still succeeds; the problem is only logged as a warning.
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.

create or replace function public.comptech_sync_faculty_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text := lower(coalesce(new.role, ''));
  v_email text;
begin
  if v_role not in ('faculty', 'professor') then
    return new;
  end if;

  v_email := coalesce(new.email, (select au.email from auth.users au where au.id = new.id));

  begin
    -- A leftover users row of a deleted account can still hold this email,
    -- which made the insert below fail. Free it by renaming the leftover's
    -- email (the row is kept). Only rows with no login account, student
    -- profile, classes, attendance or NFC cards count as leftovers.
    if not exists (select 1 from public.users p where p.id = new.id) then
      update public.users x
      set email = 'orphaned-' || x.id || '@invalid.local'
      where lower(x.email) = lower(v_email)
        and x.id <> new.id
        and not exists (select 1 from auth.users a where a.id = x.id)
        and not exists (select 1 from public.student_profiles sp where sp.id = x.id)
        and not exists (select 1 from public.class_students cs where cs.student_id = x.id)
        and not exists (select 1 from public.classes oc where oc.faculty_id = x.id)
        and not exists (select 1 from public.attendance a where a.student_id = x.id)
        and not exists (select 1 from public.student_nfc_cards n where n.student_id = x.id);
    end if;

    insert into public.users (id, email, full_name, role)
    values (
      new.id,
      v_email,
      new.full_name,
      v_role
    )
    on conflict (id) do update
      set role = excluded.role
      where public.users.role is null;
  exception when others then
    raise warning 'comptech_sync_faculty_user: could not add % to users (%)', new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_sync_faculty_user() from public, anon, authenticated;

drop trigger if exists comptech_sync_faculty_user on public.faculty_profiles;
create trigger comptech_sync_faculty_user
  after insert or update of role on public.faculty_profiles
  for each row execute function public.comptech_sync_faculty_user();

-- Add professors that were created before this file was run.
do $$
declare
  r record;
begin
  for r in
    select fp.id,
           coalesce(fp.email, au.email) as email,
           fp.full_name,
           lower(fp.role) as role
    from public.faculty_profiles fp
    left join auth.users au on au.id = fp.id
    left join public.users u on u.id = fp.id
    where lower(coalesce(fp.role, '')) in ('faculty', 'professor')
      and (u.id is null or u.role is null)
  loop
    begin
      insert into public.users (id, email, full_name, role)
      values (r.id, r.email, r.full_name, r.role)
      on conflict (id) do update
        set role = excluded.role
        where public.users.role is null;
    exception when others then
      raise warning 'Could not add % to users (%)', r.email, sqlerrm;
    end;
  end loop;
end;
$$;

-- Check: every professor should now show a users_role.
select coalesce(fp.email, au.email) as email,
       fp.role as faculty_role,
       u.role  as users_role
from public.faculty_profiles fp
left join auth.users au on au.id = fp.id
left join public.users u on u.id = fp.id
order by 1;
