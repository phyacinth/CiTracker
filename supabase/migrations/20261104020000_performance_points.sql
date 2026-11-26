-- Performance mode on the professor's NFC scanner: hands-on points entered
-- right after scanning a student's phone or card, into a hands-on column the
-- professor dashboard already has.
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.
--
-- comptech_performance_points(...) does both steps of a scan:
--   * p_points null (preview): identifies the student and lists the class's
--     hands-on columns for the term, each with the student's current score.
--     Nothing is written.
--   * p_points set: saves the points into the column p_assessment_id.
--
-- Rules:
--   * Only the class's own professor (classes.faculty_id) can use it.
--   * Hands-on columns are the class's assessments of type 'project' (shown
--     under Midterm / Final ACTIVITIES/Projects in the gradebook). The scanner
--     never creates one: new columns are made on the professor dashboard.
--   * The new score replaces the student's score in that column (one score
--     per student and column, never a second row), kept between 0 and the
--     column's maximum.
--   * Each save notifies the student (kind 'score').
--   * Scores are saved as draft, like the dashboard's own edits.
--   * An optional note (p_note) is added to the score's remarks, after any
--     earlier notes; leaving it empty keeps the remarks as they are.
--   * No attendance session or grace period is involved.
--
-- Shared with the professor dashboard (if they change these, update this file):
--   assessments       (id, class_id, title, assessment_type, term, max_score,
--                      created_at)
--   assessment_scores (assessment_id, student_id, score, remarks, status,
--                      updated_at)
--   student_nfc_cards (student_id, card_uid, card_token_hash, status)

-- Earlier versions of this file (they could create columns).
drop function if exists public.comptech_performance_points(uuid, text, text, uuid, text, text, numeric, text);
drop function if exists public.comptech_performance_points(uuid, text, text, uuid, text, text, numeric, text, text);

create or replace function public.comptech_performance_points(
  p_class_id uuid,
  p_term text,
  p_student_id uuid default null,
  p_card_uid text default null,
  p_card_payload text default null,
  p_assessment_id uuid default null,
  p_points numeric default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term text := lower(btrim(coalesce(p_term, '')));
  v_student uuid := p_student_id;
  v_token text;
  v_assessment public.assessments%rowtype;
  v_current numeric;
  v_remarks text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_score numeric;
  v_name text;
  v_number text;
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
  if v_term not in ('midterm', 'final') then
    raise exception 'INVALID_REQUEST';
  end if;
  if p_points is not null and p_points < 0 then
    raise exception 'INVALID_REQUEST';
  end if;

  -- A card identifies the student by its UID and the token written on it.
  if v_student is null then
    if p_card_payload is null
       or p_card_payload !~ '^COMPTECH:NFC:CARD:V1:[0-9a-f]{64}$' then
      raise exception 'CARD_NOT_RECOGNIZED';
    end if;
    v_token := substr(p_card_payload, length('COMPTECH:NFC:CARD:V1:') + 1);
    select c.student_id into v_student
    from public.student_nfc_cards c
    where lower(c.card_uid) = lower(btrim(coalesce(p_card_uid, '')))
      and c.card_token_hash = encode(sha256(convert_to(v_token, 'UTF8')), 'hex')
      and lower(coalesce(c.status, '')) = 'active'
    limit 1;
    if v_student is null then
      raise exception 'CARD_NOT_RECOGNIZED';
    end if;
  end if;

  if not exists (
    select 1 from public.class_students cs
    where cs.class_id = p_class_id and cs.student_id = v_student
  ) then
    raise exception 'NOT_ENROLLED';
  end if;

  select coalesce(nullif(btrim(u.full_name), ''), 'Student'), u.student_number
    into v_name, v_number
  from public.users u where u.id = v_student;

  -- Preview: the term's hands-on columns, with this student's score in each.
  if p_points is null then
    return jsonb_build_object(
      'student_id', v_student,
      'student_name', v_name,
      'student_number', v_number,
      'columns', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', a.id,
          'title', a.title,
          'max_score', a.max_score,
          'current_score', s.score,
          'remarks', s.remarks
        ) order by a.created_at, a.title)
        from public.assessments a
        left join lateral (
          select x.score, x.remarks
          from public.assessment_scores x
          where x.assessment_id = a.id and x.student_id = v_student
          order by x.updated_at desc nulls last
          limit 1
        ) s on true
        where a.class_id = p_class_id
          and lower(a.term) = v_term
          and lower(a.assessment_type) = 'project'
      ), '[]'::jsonb)
    );
  end if;

  -- Save: only into an existing hands-on column of this class and term.
  select * into v_assessment
  from public.assessments a
  where a.id = p_assessment_id
    and a.class_id = p_class_id
    and lower(a.term) = v_term
    and lower(a.assessment_type) = 'project';
  if not found then
    raise exception 'COLUMN_NOT_FOUND';
  end if;

  select s.score, s.remarks into v_current, v_remarks
  from public.assessment_scores s
  where s.assessment_id = v_assessment.id and s.student_id = v_student
  order by s.updated_at desc nulls last
  limit 1;

  v_score := greatest(0, least(coalesce(v_assessment.max_score, p_points), p_points));

  -- A new note goes after earlier ones; no note keeps the remarks as is.
  v_remarks := left(
    case
      when v_note is null then v_remarks
      when nullif(btrim(coalesce(v_remarks, '')), '') is null then v_note
      else v_remarks || E'\n' || v_note
    end,
    1000);

  -- Replace the student's score in this column; never a second row.
  update public.assessment_scores s
  set score = v_score, remarks = v_remarks, status = 'draft', updated_at = now()
  where s.assessment_id = v_assessment.id and s.student_id = v_student;

  if not found then
    insert into public.assessment_scores
      (assessment_id, student_id, score, remarks, status, updated_at)
    values
      (v_assessment.id, v_student, v_score, v_remarks, 'draft', now());
  end if;

  -- Tell the student. A notification problem must not undo the saved score.
  begin
    insert into public.comptech_student_notifications
      (student_id, class_id, kind, title, body)
    select
      v_student,
      p_class_id,
      'score',
      case when v_current is null then 'New hands-on score'
           else 'Hands-on score updated' end,
      v_assessment.title
        || coalesce(' · ' || nullif(btrim(c.subject), ''), '')
        || ': ' || trim_scale(v_score)::text || ' / '
        || trim_scale(v_assessment.max_score)::text
        || case
             when v_current is not null
               then ' (was ' || trim_scale(v_current)::text || ')'
             else ''
           end
        || E'\nYour professor may still change it until grades are published.'
    from public.classes c
    where c.id = p_class_id;
  exception when others then
    raise warning 'comptech_performance_points notification: %', sqlerrm;
  end;

  return jsonb_build_object(
    'student_id', v_student,
    'student_name', v_name,
    'student_number', v_number,
    'assessment_title', v_assessment.title,
    'max_score', v_assessment.max_score,
    'previous_score', v_current,
    'score', v_score,
    'remarks', v_remarks
  );
end;
$$;

revoke all on function public.comptech_performance_points(uuid, text, uuid, text, text, uuid, numeric, text)
  from public, anon;
grant execute on function public.comptech_performance_points(uuid, text, uuid, text, text, uuid, numeric, text)
  to authenticated;

notify pgrst, 'reload schema';
