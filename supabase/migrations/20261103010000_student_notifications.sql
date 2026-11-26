-- Student notifications: the bell in the top right of the student app.
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.
--
-- One row per student per notification. Students can read their own rows and
-- mark them read through comptech_mark_my_notifications_read(); they cannot
-- insert, edit or delete rows. Rows are written by the database itself:
--   kind 'attendance'  trigger on attendance: a professor marks or changes a status
--   kind 'score'       trigger on assessment_scores: a score is published or changed
--   kind 'letter'      trigger on student_requests: a professor replies or changes status
--   kind 'schedule'    trigger on class_reschedules: a make-up class is added,
--                      changed or removed
--   kind 'message'     comptech_send_class_notification(), called by the
--                      professor dashboard
--
-- Every trigger catches its own errors, so a notification problem never
-- blocks the professor's save.
--
-- Shared with the professor dashboard (if they change these, update this file):
--   classes             (id, subject, faculty_id)
--   class_students      (class_id, student_id)
--   attendance          (session_id, student_id, status)
--   attendance_sessions (id, class_id, started_at)
--   assessments         (id, class_id, title, max_score)
--   assessment_scores   (assessment_id, student_id, score, status = 'published')
--   student_requests    (class_id, student_id as text, category, status, faculty_reply)
--   class_reschedules   (class_id, original_date, replacement_date, start_time,
--                        end_time, room, reason, mode)

create table if not exists public.comptech_student_notifications (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  class_id uuid,
  kind text not null,
  title text not null check (char_length(title) between 1 and 200),
  body text check (char_length(body) <= 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);

-- Kept separate from the table so re-running this file updates the list on a
-- table created by an earlier version.
alter table public.comptech_student_notifications
  drop constraint if exists comptech_student_notifications_kind_check;
alter table public.comptech_student_notifications
  add constraint comptech_student_notifications_kind_check
  check (kind in ('message', 'score', 'letter', 'attendance', 'schedule', 'class',
                  'activity'));

create index if not exists comptech_student_notifications_student_idx
  on public.comptech_student_notifications (student_id, created_at desc);

alter table public.comptech_student_notifications enable row level security;

drop policy if exists "students read own notifications"
  on public.comptech_student_notifications;
create policy "students read own notifications"
  on public.comptech_student_notifications for select to authenticated
  using (student_id = auth.uid());

revoke all on public.comptech_student_notifications from anon;
grant select on public.comptech_student_notifications to authenticated;

-- Live updates for the bell's unread badge.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'comptech_student_notifications'
  ) then
    alter publication supabase_realtime
      add table public.comptech_student_notifications;
  end if;
end;
$$;

create or replace function public.comptech_mark_my_notifications_read()
returns integer
language sql
security definer
set search_path = ''
as $$
  with marked as (
    update public.comptech_student_notifications n
    set read_at = now()
    where n.student_id = auth.uid() and n.read_at is null
    returning 1
  )
  select count(*)::integer from marked;
$$;

revoke all on function public.comptech_mark_my_notifications_read()
  from public, anon;
grant execute on function public.comptech_mark_my_notifications_read()
  to authenticated;

-- Attendance: notify when a professor marks or changes a student's status.
-- Present check-ins (QR, NFC) are inserted as 'present' and are skipped, so
-- students aren't notified about their own scans; so are location-only
-- updates, which don't change the status.
create or replace function public.comptech_notify_attendance_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text := lower(coalesce(new.status, ''));
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;
  if tg_op = 'INSERT' and v_status = 'present' then
    return new;
  end if;

  -- A notification problem must never block the professor's attendance save.
  begin
    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select
      new.student_id,
      s.class_id,
      'attendance',
      'Attendance updated',
      'Your attendance'
        || coalesce(' in ' || nullif(btrim(c.subject), ''), '')
        || ' for '
        || coalesce(
             to_char(s.started_at at time zone 'Asia/Manila', 'Mon DD, YYYY'),
             'a class session')
        || ' is now ' || coalesce(initcap(nullif(v_status, '')), 'updated') || '.'
    from public.attendance_sessions s
    left join public.classes c on c.id = s.class_id
    where s.id = new.session_id;
  exception when others then
    raise warning 'comptech_notify_attendance_change: %', sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_notify_attendance_change()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_attendance_change on public.attendance;
create trigger comptech_notify_attendance_change
  after insert or update of status on public.attendance
  for each row execute function public.comptech_notify_attendance_change();

-- Scores: notify when a professor publishes a score, or changes one that is
-- already published. Drafts and remark-only edits are skipped.
create or replace function public.comptech_notify_score_published()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_score text;
begin
  if lower(coalesce(new.status, '')) <> 'published' then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and lower(coalesce(old.status, '')) = 'published'
     and new.score is not distinct from old.score then
    return new;
  end if;

  -- "18" rather than "18.00"; falls back to the raw value if it isn't a number.
  begin
    v_score := trim_scale(new.score::numeric)::text;
  exception when others then
    v_score := new.score::text;
  end;

  begin
    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select
      new.student_id,
      a.class_id,
      'score',
      case
        when tg_op = 'UPDATE' and lower(coalesce(old.status, '')) = 'published'
          then 'Score updated'
        else 'New score published'
      end,
      coalesce(nullif(btrim(a.title), ''), 'An assessment')
        || coalesce(' in ' || nullif(btrim(c.subject), ''), '')
        || coalesce(': ' || v_score || coalesce(' / ' || a.max_score::text, ''), '')
    from public.assessments a
    left join public.classes c on c.id = a.class_id
    where a.id = new.assessment_id;
  exception when others then
    raise warning 'comptech_notify_score_published: %', sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_notify_score_published()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_score_published on public.assessment_scores;
create trigger comptech_notify_score_published
  after insert or update of status, score on public.assessment_scores
  for each row execute function public.comptech_notify_score_published();

-- Letters: notify when a professor replies to a letter or changes its status.
-- `student_requests.student_id` is text, so it is checked before converting.
create or replace function public.comptech_notify_letter_reply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reply text := nullif(btrim(new.faculty_reply), '');
begin
  if new.faculty_reply is not distinct from old.faculty_reply
     and new.status is not distinct from old.status then
    return new;
  end if;
  if new.student_id is null
     or new.student_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return new;
  end if;

  begin
    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select
      new.student_id::uuid,
      new.class_id,
      'letter',
      case
        when v_reply is not null
             and new.faculty_reply is distinct from old.faculty_reply
          then 'Your professor replied to your letter'
        else 'Your letter is now ' || coalesce(initcap(nullif(btrim(new.status), '')), 'updated')
      end,
      concat_ws(' · ',
        nullif(btrim(new.category), ''),
        nullif(btrim(c.subject), ''))
        || coalesce(E'\n' || left(v_reply, 300), '')
    from (select 1) one
    left join public.classes c on c.id = new.class_id;
  exception when others then
    raise warning 'comptech_notify_letter_reply: %', sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_notify_letter_reply()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_letter_reply on public.student_requests;
create trigger comptech_notify_letter_reply
  after update of faculty_reply, status on public.student_requests
  for each row execute function public.comptech_notify_letter_reply();

-- Make-up classes: notify every student in the class when a professor adds,
-- changes (date, time or room) or removes one in class_reschedules.
create or replace function public.comptech_notify_class_reschedule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.class_reschedules%rowtype;
  v_label text;
  v_date text;
  v_original text;
  v_time text;
  v_body text;
begin
  if tg_op = 'DELETE' then
    r := old;
  else
    r := new;
  end if;

  -- An edit that only touches the reason or other details isn't worth a ping.
  if tg_op = 'UPDATE'
     and new.replacement_date is not distinct from old.replacement_date
     and new.original_date is not distinct from old.original_date
     and new.start_time is not distinct from old.start_time
     and new.end_time is not distinct from old.end_time
     and new.room is not distinct from old.room then
    return new;
  end if;

  begin
    v_label := case
      when coalesce(r.mode, '') ~* 'resched|move|transfer' then 'Class rescheduled'
      else 'Make-up class'
    end;

    -- Column types aren't ours, so formatting falls back to the raw value.
    begin
      v_date := to_char(r.replacement_date::date, 'Dy, Mon DD');
    exception when others then
      v_date := r.replacement_date::text;
    end;
    begin
      v_original := to_char(r.original_date::date, 'Mon DD');
    exception when others then
      v_original := r.original_date::text;
    end;
    begin
      v_time := to_char(r.start_time::time, 'FMHH12:MI AM')
        || ' – ' || to_char(r.end_time::time, 'FMHH12:MI AM');
    exception when others then
      v_time := nullif(concat_ws(' – ', r.start_time::text, r.end_time::text), '');
    end;

    v_body := concat_ws(', ', v_date, v_time, nullif(btrim(r.room), ''))
      || case
           when v_original is not null and v_original is distinct from v_date
             then ' (for the ' || v_original || ' class)'
           else ''
         end
      || coalesce(E'\nReason: ' || nullif(btrim(r.reason), ''), '');

    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select distinct
      cs.student_id,
      r.class_id,
      'schedule',
      left(
        v_label
          || case tg_op when 'UPDATE' then ' updated' when 'DELETE' then ' cancelled' else '' end
          || coalesce(': ' || nullif(btrim(c.subject), ''), ''),
        200),
      left(v_body, 2000)
    from public.class_students cs
    left join public.classes c on c.id = r.class_id
    where cs.class_id = r.class_id;
  exception when others then
    raise warning 'comptech_notify_class_reschedule: %', sqlerrm;
  end;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.comptech_notify_class_reschedule()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_class_reschedule on public.class_reschedules;
create trigger comptech_notify_class_reschedule
  after insert or update or delete on public.class_reschedules
  for each row execute function public.comptech_notify_class_reschedule();

-- Professor messages. The professor dashboard calls this to message a whole
-- class, or one student in it with p_student_id. Only the class's own
-- professor (classes.faculty_id) can send. Returns how many students got it.
create or replace function public.comptech_send_class_notification(
  p_class_id uuid,
  p_title text,
  p_body text default null,
  p_student_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text := btrim(coalesce(p_title, ''));
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_sent integer;
begin
  if auth.uid() is null then
    raise exception 'SIGN_IN_REQUIRED';
  end if;

  if not exists (
    select 1 from public.classes c
    where c.id = p_class_id and c.faculty_id = auth.uid()
  ) then
    raise exception 'CLASS_NOT_OWNED';
  end if;

  if char_length(v_title) not between 1 and 200
     or char_length(coalesce(v_body, '')) > 2000 then
    raise exception 'INVALID_REQUEST';
  end if;

  insert into public.comptech_student_notifications
    (student_id, class_id, kind, title, body)
  select distinct cs.student_id, p_class_id, 'message', v_title, v_body
  from public.class_students cs
  where cs.class_id = p_class_id
    and (p_student_id is null or cs.student_id = p_student_id);

  get diagnostics v_sent = row_count;

  if p_student_id is not null and v_sent = 0 then
    raise exception 'NOT_ENROLLED';
  end if;

  return v_sent;
end;
$$;

revoke all on function public.comptech_send_class_notification(uuid, text, text, uuid)
  from public, anon;
grant execute on function public.comptech_send_class_notification(uuid, text, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
