-- Notify students when their class is archived.
--
-- Run this whole file in the Supabase SQL Editor after
-- 20261103010000_student_notifications.sql. It is safe to run again.
--
-- When the professor dashboard archives a class (classes.status becomes
-- 'Archived'), every enrolled student gets a notification (kind 'class').
-- Tapping it in the app opens Attendance & Classes, where archived classes
-- are listed. Nothing is sent when a class is restored or edited.
--
-- Shared with the professor dashboard (if they change these, update this file):
--   classes        (id, subject, section, status = 'Archived')
--   class_students (class_id, student_id)

-- Allow the new 'class' kind (the list is kept in one constraint).
alter table public.comptech_student_notifications
  drop constraint if exists comptech_student_notifications_kind_check;
alter table public.comptech_student_notifications
  add constraint comptech_student_notifications_kind_check
  check (kind in ('message', 'score', 'letter', 'attendance', 'schedule', 'class',
                  'activity'));

create or replace function public.comptech_notify_class_archived()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if lower(btrim(coalesce(new.status, ''))) <> 'archived'
     or lower(btrim(coalesce(old.status, ''))) = 'archived' then
    return new;
  end if;

  -- A notification problem must never block archiving the class.
  begin
    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select distinct
      cs.student_id,
      new.id,
      'class',
      left('Class archived: ' || coalesce(nullif(btrim(new.subject), ''), 'a class'), 200),
      coalesce(nullif(btrim(new.subject), ''), 'This class')
        || coalesce(' (' || nullif(btrim(new.section), '') || ')', '')
        || ' was archived by your professor. Its records are kept, and it'
        || ' now appears under Archived Classes.'
    from public.class_students cs
    where cs.class_id = new.id;
  exception when others then
    raise warning 'comptech_notify_class_archived: %', sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_notify_class_archived()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_class_archived on public.classes;
create trigger comptech_notify_class_archived
  after update of status on public.classes
  for each row execute function public.comptech_notify_class_archived();
