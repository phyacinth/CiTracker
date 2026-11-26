-- Hide archived classes from the student app's subject lists.
--
-- Run this whole file in the Supabase SQL Editor. It is safe to run again.
--
-- The professor dashboard archives a class by setting classes.status. The
-- student app gets its class lists from several functions, some owned by the
-- professor dashboard, so instead of changing each one it asks this function
-- which of the student's classes are archived and leaves those out.
-- Archived classes keep all their records; they are only hidden from the
-- student's subject choices.
--
-- Shared with the professor dashboard (if they change it, update this file):
--   classes.status = 'archived' for an archived class

create or replace function public.comptech_my_archived_class_ids()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(c.id), '[]'::jsonb)
  from public.classes c
  where lower(btrim(coalesce(c.status, ''))) = 'archived'
    and exists (
      select 1 from public.class_students cs
      where cs.class_id = c.id and cs.student_id = auth.uid()
    );
$$;

revoke all on function public.comptech_my_archived_class_ids() from public, anon;
grant execute on function public.comptech_my_archived_class_ids() to authenticated;

notify pgrst, 'reload schema';
