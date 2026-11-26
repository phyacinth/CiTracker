-- Repair: sessions started on the professor dashboard don't show in the
-- student's NFC Use Card ("No active attendance session").
--
-- Cause: a session only works with NFC once it has a row in
-- nfc_attendance_test_sessions. The database adds that row automatically
-- (trigger initialize_nfc_session_policy), and the card check-in checks the
-- same thing (nfc_attendance_guard), but only when the class's professor has
-- a public.users row with role 'faculty' or 'professor'. Some dashboard
-- professors have none: 20261102000000_sync_faculty_to_users.sql adds it,
-- but only logs a warning when that fails. Their sessions were skipped.
--
-- Why adding it failed: another users row already had the professor's email.
-- Those rows were leftovers of deleted accounts (no login account, no
-- student profile, no classes, attendance or NFC cards).
--
-- This file:
--   0. frees an email held by such a leftover row, by renaming the leftover's
--      email to orphaned-<its id>@invalid.local (the row itself is kept, so
--      nothing that points at it breaks);
--   1. adds the missing users row for every professor who owns a class and
--      has a faculty_profiles row (it never changes an existing role and
--      never touches students);
--   2. adds the NFC row for sessions that are active and still inside their
--      30-minute window, so nobody has to restart them;
--   3. lists every class-owning professor, so you can check none is left
--      without a role (see the comments at the end).
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.

-- 0. Free emails that leftover rows hold for professors who own a class
--    but have no users row. A row only counts as a leftover when it has no
--    login account, no student profile, no classes (joined or owned), no
--    attendance and no NFC cards.
update public.users x
set email = 'orphaned-' || x.id || '@invalid.local'
from public.classes c
join public.faculty_profiles fp on fp.id = c.faculty_id
left join auth.users au on au.id = c.faculty_id
where lower(x.email) = lower(coalesce(fp.email, au.email))
  and x.id <> c.faculty_id
  and not exists (select 1 from public.users p where p.id = c.faculty_id)
  and not exists (select 1 from auth.users a where a.id = x.id)
  and not exists (select 1 from public.student_profiles sp where sp.id = x.id)
  and not exists (select 1 from public.class_students cs where cs.student_id = x.id)
  and not exists (select 1 from public.classes oc where oc.faculty_id = x.id)
  and not exists (select 1 from public.attendance a where a.student_id = x.id)
  and not exists (select 1 from public.student_nfc_cards n where n.student_id = x.id);

-- 1. Missing users rows.
do $$
declare
  r record;
begin
  for r in
    select distinct
           c.faculty_id as id,
           coalesce(fp.email, au.email) as email,
           coalesce(nullif(btrim(fp.full_name), ''),
                    au.raw_user_meta_data ->> 'full_name') as full_name,
           case
             when lower(coalesce(fp.role, '')) in ('faculty', 'professor')
               then lower(fp.role)
             else 'faculty'
           end as role
    from public.classes c
    join public.faculty_profiles fp on fp.id = c.faculty_id
    left join auth.users au on au.id = c.faculty_id
    left join public.users u on u.id = c.faculty_id
    where u.id is null or u.role is null
  loop
    begin
      insert into public.users (id, email, full_name, role)
      values (r.id, r.email, r.full_name, r.role)
      on conflict (id) do update
        set role = excluded.role
        where public.users.role is null;
      raise notice 'Added % (%) to users as %', r.email, r.id, r.role;
    exception when others then
      raise warning 'Could not add % (%) to users: %', r.email, r.id, sqlerrm;
    end;
  end loop;
end;
$$;

-- 2. NFC rows for sessions still in their window, using the same rules and
-- 30-minute window as initialize_nfc_session_policy.
insert into public.nfc_attendance_test_sessions (session_id, grace_minutes, expires_at)
select s.id, 30, s.started_at + interval '30 minutes'
from public.attendance_sessions s
join public.classes c on c.id = s.class_id
join public.users u on u.id = c.faculty_id
where s.status = 'active'
  and s.ended_at is null
  and s.started_at is not null
  and s.started_at + interval '30 minutes' > now()
  and s.started_by = c.faculty_id
  and u.role in ('faculty', 'professor')
  and coalesce(lower(c.status), 'active') in ('active', 'scheduled')
on conflict (session_id) do nothing;

-- 3. Check. Every row should show users_role faculty or professor.
--    * users_role empty and has_faculty_profile false: the professor was
--      never saved in faculty_profiles; save them on the dashboard again.
--    * users_role empty and other_users_with_same_email > 0: another users
--      row uses their email and isn't a leftover (it has a login account or
--      records), so it was left alone. That needs a look by hand.
--    * users_role 'student': this professor's account is set up as a
--      student; it needs to be corrected by hand.
select coalesce(fp.email, au.email) as email,
       owner.id as professor_id,
       fp.id is not null as has_faculty_profile,
       fp.role as faculty_profile_role,
       u.role as users_role,
       (select count(*) from public.users x
        where lower(x.email) = lower(coalesce(fp.email, au.email))
          and x.id <> owner.id) as other_users_with_same_email
from (select distinct faculty_id as id from public.classes
      where faculty_id is not null) owner
left join public.faculty_profiles fp on fp.id = owner.id
left join auth.users au on au.id = owner.id
left join public.users u on u.id = owner.id
order by u.role nulls first, 1;
