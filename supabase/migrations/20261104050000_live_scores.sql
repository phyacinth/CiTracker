-- Live scores: the student app's Scores screen follows the professor's
-- gradebook as it is edited, instead of waiting for Publish.
--
-- Run this whole file in the Supabase SQL Editor (after
-- 20261103020000_published_gradebook.sql). It is safe to run again.
--
-- comptech_my_published_scores (the name is kept so the app doesn't change
-- which function it calls) now returns, per class:
--   grade        the latest grade summary the professor saved in
--                student_grades, Draft or published, with its status.
--                The dashboard calculates the final grade in the
--                professor's browser, so it only reaches the database (and
--                the app) when the professor saves Draft or publishes.
--   assessments  every score the professor has saved for the student,
--                Draft or published.
--
-- comptech_my_scores_version() returns a short fingerprint of the student's
-- scores, grade summaries and their assessments. The app asks for it every
-- few seconds and reloads the Scores screen only when it changes.
--
-- Notifications are unchanged: students are notified when the professor
-- publishes or republishes, not on every Draft edit (the dashboard saves
-- each keystroke, so that would flood them).
--
-- Shared with the professor dashboard (if they change these, update this file):
--   student_grades    (class_id, student_id, final_grade, *_percentage,
--                      remarks, status, published_at, updated_at)
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
            'status', lower(coalesce(g.status, 'draft')),
            'published_at', g.published_at,
            'updated_at', g.updated_at
          )
          from public.student_grades g
          where g.class_id = c.id
            and g.student_id::text = v_uid::text
          order by g.updated_at desc nulls last, g.published_at desc nulls last
          limit 1
        ),
        'assessments', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', a.id, 'title', a.title, 'type', a.assessment_type,
            'term', a.term, 'max_score', a.max_score, 'weight', a.weight,
            'date', a.assessment_date, 'score', s.score,
            'remarks', s.remarks, 'updated_at', s.updated_at,
            'status', lower(coalesce(s.status, 'draft'))
          ) order by a.assessment_date nulls last, a.created_at, a.id)
          from public.assessments a
          join public.assessment_scores s on s.assessment_id = a.id
          where a.class_id = c.id
            and s.student_id = v_uid
            and s.score is not null
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

-- Fingerprint of everything the Scores screen shows for this student.
create or replace function public.comptech_my_scores_version()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(concat_ws('|',
    (select string_agg(
              concat_ws(',', s.assessment_id, s.score, s.status, s.remarks,
                        s.updated_at, a.title, a.max_score, a.term,
                        a.assessment_type),
              ';' order by s.assessment_id)
     from public.assessment_scores s
     join public.assessments a on a.id = s.assessment_id
     where s.student_id = auth.uid()),
    (select string_agg(
              concat_ws(',', g.class_id, g.final_grade, g.status,
                        g.published_at, g.updated_at, g.remarks),
              ';' order by g.class_id, g.updated_at)
     from public.student_grades g
     where g.student_id::text = auth.uid()::text),
    (select string_agg(cs.class_id::text, ';' order by cs.class_id)
     from public.class_students cs
     where cs.student_id = auth.uid())
  ));
$$;

revoke all on function public.comptech_my_scores_version() from public, anon;
grant execute on function public.comptech_my_scores_version() to authenticated;

notify pgrst, 'reload schema';
