-- Notify students when their professor adds an activity to a class.
--
-- Run this whole file in the Supabase SQL Editor after
-- 20261103010000_student_notifications.sql. It is safe to run again.
--
-- When the professor dashboard adds an assessment or reminder on Activities
-- (a new faculty_reminders row: quiz, exam, class activity or hands-on
-- activity), every student enrolled in that class gets a notification
-- (kind 'activity'). Tapping it in the app opens Home on that class, where
-- the activity is listed under Upcoming Activities.
--
-- Nothing is sent for edits or deletions, or for an activity dated before
-- today (Philippine time), which wouldn't be upcoming.
--
-- Shared with the professor dashboard (if they change these, update this file):
--   faculty_reminders (class_id, reminder_date, title, description,
--                      activity_type, start_time, end_time)
--   classes           (id, subject)
--   class_students    (class_id, student_id)

-- Allow the new 'activity' kind (the list is kept in one constraint).
alter table public.comptech_student_notifications
  drop constraint if exists comptech_student_notifications_kind_check;
alter table public.comptech_student_notifications
  add constraint comptech_student_notifications_kind_check
  check (kind in ('message', 'score', 'letter', 'attendance', 'schedule', 'class',
                  'activity'));

create or replace function public.comptech_notify_activity_added()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
  v_when text;
  v_time text;
  v_type text := nullif(btrim(new.activity_type), '');
  v_title text := coalesce(nullif(btrim(new.title), ''), v_type, 'An activity');
begin
  -- A notification problem must never block the professor's save.
  begin
    -- Column types aren't ours, so formatting falls back to the raw value.
    begin
      v_date := new.reminder_date::date;
      v_when := to_char(v_date, 'Dy, Mon DD');
    exception when others then
      v_date := null;
      v_when := nullif(btrim(new.reminder_date::text), '');
    end;

    if v_date is not null
       and v_date < (now() at time zone 'Asia/Manila')::date then
      return new;
    end if;

    begin
      v_time := to_char(new.start_time::time, 'FMHH12:MI AM')
        || ' – ' || to_char(new.end_time::time, 'FMHH12:MI AM');
    exception when others then
      v_time := nullif(concat_ws(' – ', new.start_time::text, new.end_time::text), '');
    end;

    -- class_id is compared as text, since the dashboard's column type isn't ours.
    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select distinct
      cs.student_id,
      c.id,
      'activity',
      left(
        'New ' || lower(coalesce(v_type, 'activity'))
          || coalesce(': ' || nullif(btrim(c.subject), ''), ''),
        200),
      left(
        v_title
          || coalesce(E'\n' || nullif(concat_ws(', ', v_when, v_time), ''), '')
          -- The dashboard copies the title into the description for
          -- activities without one, so that isn't repeated.
          || coalesce(E'\n' || nullif(nullif(btrim(new.description), ''), v_title), ''),
        2000)
    from public.classes c
    join public.class_students cs on cs.class_id = c.id
    where c.id::text = new.class_id::text;
  exception when others then
    raise warning 'comptech_notify_activity_added: %', sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_notify_activity_added()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_activity_added on public.faculty_reminders;
create trigger comptech_notify_activity_added
  after insert on public.faculty_reminders
  for each row execute function public.comptech_notify_activity_added();
