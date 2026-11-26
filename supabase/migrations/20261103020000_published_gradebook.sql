-- Student Scores screen: show grades the professor publishes as a gradebook.
--
-- Run this whole file in the Supabase SQL Editor after
-- 20261103010000_student_notifications.sql. It is safe to run again.
--
-- The professor dashboard's "Publish / Republish grades" saves a summary row
-- in `student_grades` (status 'published', published_at) and leaves each
-- assessment and score as 'draft'. Before this file, the student app only
-- showed scores marked 'published' one by one, so nothing appeared.
--
-- comptech_my_published_scores now returns, per class:
--   grade        the published `student_grades` summary, or null
--   assessments  scores marked 'published', plus, once the gradebook is
--                published, scores saved up to that moment. Later edits stay
--                hidden until the professor republishes. published_at comes
--                from the professor's computer clock, so 5 minutes of leeway
--                cover a clock that runs a little slow.
--
-- Shared with the professor dashboard (if they change these, update this file):
--   student_grades    (class_id, student_id, final_grade, *_percentage,
--                      remarks, status = 'published', published_at)
--   assessments       (id, class_id, title, assessment_type, term, max_score,
--                      weight, assessment_date, created_at)
--   assessment_scores (assessment_id, student_id, score, status, remarks,
--                      updated_at)

create or replace function public.comptech_my_published_scores()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null or not exists (
    select 1 from public.users where id = v_uid and role = 'student'
  ) then
    raise exception 'Please sign in with a student account.';
  end if;

  select jsonb_build_object(
    'student_number', u.student_number,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'subject', c.subject,
        'section', c.section,
        'grade', (
          select jsonb_build_object(
            'final_grade', g.final_grade,
            'exam_percentage', g.exam_percentage,
            'quiz_percentage', g.quiz_percentage,
            'project_percentage', g.project_percentage,
            'recitation_percentage', g.recitation_percentage,
            'attendance_percentage', g.attendance_percentage,
            'remarks', g.remarks,
            'published_at', g.published_at
          )
          from public.student_grades g
          where g.class_id = c.id
            and g.student_id::text = v_uid::text
            and lower(coalesce(g.status, '')) = 'published'
          order by g.published_at desc nulls last
          limit 1
        ),
        'assessments', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', a.id, 'title', a.title, 'type', a.assessment_type,
            'term', a.term, 'max_score', a.max_score, 'weight', a.weight,
            'date', a.assessment_date, 'score', s.score,
            'remarks', s.remarks, 'updated_at', s.updated_at
          ) order by a.assessment_date nulls last, a.created_at, a.id)
          from public.assessments a
          join public.assessment_scores s on s.assessment_id = a.id
          where a.class_id = c.id
            and s.student_id = v_uid
            and (
              s.status = 'published'
              or exists (
                select 1 from public.student_grades g
                where g.class_id = c.id
                  and g.student_id::text = v_uid::text
                  and lower(coalesce(g.status, '')) = 'published'
                  and g.published_at is not null
                  and s.updated_at <= g.published_at + interval '5 minutes'
              )
            )
        ), '[]'::jsonb)
      ) order by c.subject, c.id)
      from public.classes c
      where exists (
        select 1 from public.class_students cs
        where cs.class_id = c.id and cs.student_id = v_uid
      )
    ), '[]'::jsonb)
  ) into v_result
  from public.users u
  where u.id = v_uid;

  return v_result;
end;
$$;

revoke all on function public.comptech_my_published_scores() from public, anon;
grant execute on function public.comptech_my_published_scores() to authenticated;

-- Notify the student when their gradebook is published or republished.
-- Uses kind 'score', so tapping it opens the Scores tab.
create or replace function public.comptech_notify_grades_published()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grade text;
begin
  if lower(coalesce(new.status, '')) <> 'published' then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and lower(coalesce(old.status, '')) = 'published'
     and new.published_at is not distinct from old.published_at then
    return new;
  end if;
  if new.student_id is null
     or new.student_id::text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return new;
  end if;

  begin
    begin
      v_grade := trim_scale(new.final_grade::numeric)::text;
    exception when others then
      v_grade := new.final_grade::text;
    end;

    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select
      new.student_id::text::uuid,
      new.class_id,
      'score',
      case
        when tg_op = 'UPDATE' and lower(coalesce(old.status, '')) = 'published'
          then 'Grades updated'
        else 'Grades published'
      end || coalesce(': ' || nullif(btrim(c.subject), ''), ''),
      coalesce('Final grade: ' || v_grade, 'Your grades are now available.')
    from (select 1) one
    left join public.classes c on c.id = new.class_id;
  exception when others then
    raise warning 'comptech_notify_grades_published: %', sqlerrm;
  end;

  return new;
end;
$$;

revoke all on function public.comptech_notify_grades_published()
  from public, anon, authenticated;

drop trigger if exists comptech_notify_grades_published on public.student_grades;
create trigger comptech_notify_grades_published
  after insert or update of status, published_at on public.student_grades
  for each row execute function public.comptech_notify_grades_published();

notify pgrst, 'reload schema';
