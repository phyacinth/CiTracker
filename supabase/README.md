# Supabase setup for the Student App

Student QR attendance does **not** use the `qr-attendance` Edge Function. That
function belongs to the professor dashboard team and only issues QR codes.
Students check in through two database functions that this repo owns:

- `comptech_student_submit_qr_attendance`
- `comptech_student_qr_attendance_status`

Both are created by `migrations/20261101000000_student_qr_attendance.sql`.
`migrations/20261103000000_attendance_location.sql` then adds `check_in_*`
location columns to `attendance` and replaces the submit function with one
that also saves where the student was when they scanned: coordinates,
accuracy, distance from the building, whether that counts as on campus, a
fake-GPS flag, and a place name. On campus the place name is the official
`campus_name` from settings; elsewhere it is the phone's area name, such as
"Guinhawa, Malolos, Bulacan". The professor dashboard can show these columns with its
existing access to `attendance`.

NFC check-ins (card tap and phone tap) are saved by the professor dashboard's
`nfc-attendance` Edge Function, which this repo does not own. Right after an
NFC check-in succeeds, the student app calls
`comptech_student_record_check_in_location` to fill in the same columns. It
only accepts the student's own check-in from the last 5 minutes that has no
location yet. Both QR and NFC use `comptech_campus_check`, so they judge "on
campus" the same way.

Phone tap has one gap: the student's phone only notices the tap while the
app's Tap Phone screen is open. If the app is in the background, that
check-in shows "Not recorded" for location.

## First-time setup

1. Open the Supabase dashboard and make sure the project ID in the address bar
   is `imdigrgakhikhzjukygp` (the one in `lib/main.dart`).
2. Go to **SQL Editor → New query**.
3. Open `supabase/migrations/20261101000000_student_qr_attendance.sql`, copy
   **all** of it, paste it in, and click **Run**.
   You should see `Success. No rows returned`.
   Then do the same with
   `supabase/migrations/20261103000000_attendance_location.sql`.
4. Check that both functions exist:

   ```sql
   select proname from pg_proc
   where proname like 'comptech_student_%qr_attendance%';
   ```

   You should get two rows. Also check the location columns exist:

   ```sql
   select check_in_location, check_in_on_campus from public.attendance limit 1;
   ```

   Then set the building location. Until this is set, the distance and
   on-campus columns stay empty:

   ```sql
   insert into public.comptech_campus_settings
     (latitude, longitude, radius_m, max_accuracy_m, campus_name)
   values (14.8577015, 120.8125818, 100, 100,
     'College of Industrial Technology, Bulacan State University, Brgy. Guinhawa, Malolos, Bulacan')
   on conflict (id) do update set latitude = excluded.latitude,
     longitude = excluded.longitude, radius_m = excluded.radius_m,
     max_accuracy_m = excluded.max_accuracy_m,
     campus_name = excluded.campus_name, updated_at = now();
   ```

   - `latitude`, `longitude`: the building, from Google Maps (long-press it).
   - `radius_m`: how far from that point still counts as on campus.
   - `max_accuracy_m`: GPS readings less accurate than this are not trusted,
     even inside the radius. `null` turns the limit off.
   - `campus_name`: what on-campus scans show as their location.

   To tune the radius, do test scans inside the building and just outside it,
   then compare:

   ```sql
   select check_in_time, check_in_distance_m, check_in_accuracy_m, check_in_on_campus
   from public.attendance order by check_in_time desc limit 10;
   ```

   Set `radius_m` a little above the largest distance seen from inside the
   building, and run the `insert` again to change it.
5. Rebuild the app on the phone (stop it and run again; hot reload is not enough).
6. Test: the professor starts a session and shows a QR code, and a student who
   is enrolled in that class scans it within 15 minutes of the session starting.

## When QR check-in breaks

| Message in the app | What to do |
| --- | --- |
| Student QR check-in is not set up in the database yet | The functions were deleted. Repeat **First-time setup** steps 1–4. |
| This QR was replaced / This QR expired | Scan the newest code on the professor's screen. |
| The grace period has ended | Check-in only works in the first 15 minutes of a session. |
| You are not enrolled in this class | The student is missing from `class_students` for that class. |
| Attendance could not be confirmed / server error | The professor team probably changed `attendance_sessions` or `attendance_qr_tokens`. Compare their columns with the list at the top of the SQL file, update the SQL, and run it again. |

Running a SQL file again is safe: it replaces the functions and does not touch
any attendance data. The one exception: once the location file has been run,
don't re-run `20261101000000_student_qr_attendance.sql` on its own. It would
recreate the old 3-argument submit function next to the new one, and check-in
would fail because the database can't tell them apart. If that happens, run
the location file again (it drops the old version).

## Professors from the professor dashboard

The professor dashboard saves professors in `faculty_profiles` only, but the
app's login and `nfc-attendance` look them up in `users`.
`migrations/20261102000000_sync_faculty_to_users.sql` adds a database rule that
creates the matching `users` row (role `faculty` or `professor`) whenever a
professor is saved, and fills in professors that already exist.

Run it once in the SQL Editor. The last part of the file lists every
professor: each one should show a `users_role`. If one doesn't, the
**Messages** tab shows a warning explaining why.

A professor without a `users` row also breaks NFC: their sessions never get
the `nfc_attendance_test_sessions` row that NFC check-in needs, so students'
**Use Card** says "No active attendance session" even while the dashboard
shows it running. `migrations/20261104040000_repair_professor_nfc_sessions.sql`
adds the missing `users` rows for professors who own classes, adds the NFC
row for sessions still inside their 30-minute window, and lists every
professor so you can check none is left without a role (the file explains
what each result means). Run it whenever a professor's sessions don't show
in Use Card.

The usual reason the `users` row was missing: a leftover `users` row from a
deleted account still held the professor's email. Both the repair file and
the faculty sync (run `20261102000000_sync_faculty_to_users.sql` again to
update it) now rename such a leftover's email to
`orphaned-<id>@invalid.local` and keep the row. A row only counts as a
leftover if it has no login account, student profile, classes, attendance or
NFC cards.

## Lost or replaced student phones

Each account has one active phone. Run both files once:
`migrations/20261102010000_approve_phone_replacement.sql` and
`migrations/20261102020000_self_service_phone_replacement.sql`.

**Now (self-service, no approval):** on the new phone, the student opens
**NFC Attendance → Phone Setup** and taps the NFC logo three times. The new
phone is registered and the old one stops working for attendance. Each
replacement is still recorded in `nfc_phone_replacement_approvals` with
`approved_by = 'self-service'`.

**To require approvals again:** in the self-service file, change
`v_self_service constant boolean := true;` to `false` and run it again. Then
replacements work like this:

1. On the new phone, the student opens **NFC Attendance → Phone Setup** and
   taps the NFC logo three times. The app shows **Replacement approval needed**
   and a phone code under **Registration details** (**Copy phone code**).
2. The student sends that code to a professor or admin.
3. The admin runs in the SQL Editor:

   ```sql
   select public.comptech_approve_phone_replacement(
     'student@ms.bulsu.edu.ph', '<phone code>', 'Lost phone', 'Your name');
   ```

4. Within 24 hours, the student taps the NFC logo three times again. The old
   phone stops working and the new one is registered.

## Changing the SQL

Never edit the functions only in the dashboard. Edit the `.sql` file in this
repo, run it in the SQL Editor, and commit the file, so the repo always holds
the version that is deployed.

New database changes go in a new file in `migrations/`, named
`YYYYMMDDHHMMSS_short_description.sql`, using `comptech_student_` for function
names so they can't clash with the professor dashboard.

## Student notifications (the bell)

`migrations/20261103010000_student_notifications.sql` creates
`comptech_student_notifications`, which the bell on every student tab reads
with live updates. Students can only read their own rows and mark them read;
rows are written by the database.

Notifications are created automatically by triggers when a professor:

- marks or changes a student's attendance status (the student's own QR and
  NFC check-ins are skipped);
- publishes a score, or changes one that is already published;
- replies to a letter or changes its status;
- adds an activity to a class (see "New activity notification" below);
- adds, changes (date, time or room) or removes a make-up class
  (`class_reschedules`); every student in the class is notified.

Professor messages come from the professor dashboard, which calls:

```sql
select public.comptech_send_class_notification(
  '<class id>', 'Quiz moved to Friday', 'Bring a calculator.');
-- add a 4th argument, a student's id, to message only that student
```

Only the class's own professor (`classes.faculty_id`) can send; the function
returns how many students received it. The professor dashboard still needs a
button that calls it.

To set up, run the file in the SQL Editor like the others, then check:

```sql
select count(*) from public.comptech_student_notifications;
```

## Published gradebook (Scores screen)

The professor dashboard's **Publish / Republish grades** saves a summary in
`student_grades` and leaves each assessment and score as `draft`.
`migrations/20261103020000_published_gradebook.sql` (run after the
notifications file) makes the student app follow that:

- The Scores screen shows the published final grade and remarks.
- Each assessment score saved up to the moment of publishing is shown; edits
  made afterwards appear only after the professor republishes.
- Publishing or republishing sends a "Grades published" notification.

### Live scores

`migrations/20261104050000_live_scores.sql` (run after the file above)
makes the Scores screen follow the gradebook as the professor edits it,
instead of waiting for Publish:

- Every score the professor saves shows up for the student, Draft or
  published. The screen checks for changes every 15 seconds while it's open
  (and when the app comes back to the front) and reloads by itself.
- The final grade and percentages are calculated by the dashboard in the
  professor's browser, so they update whenever the professor saves the
  gradebook (Draft) or publishes it. Until it's published, the app says the
  grade may still change.
- Notifications are unchanged: only Publish/Republish notifies students.
- Don't re-run `20261103020000_published_gradebook.sql` after this file: it
  would switch the Scores screen back to published-only. If that happens,
  run this file again.

## Offline attendance (fallback when there's no internet)

Online attendance is unchanged. These only take over when a phone has no
internet, and everything ends up in the same `attendance` table, labelled in
`check_in_method` (`qr_offline`, `phone_tap_offline`) with `synced_at`.

| Situation | What happens |
| --- | --- |
| Student has no internet, scans QR | Saved on the student's phone, signed with their registered phone key, sent automatically when back online. |
| Professor's scanner has no internet | Phone taps only: the student's phone signs the tap over NFC, the scanner saves it with its own location and uploads later. A session can be started offline. Card taps still need internet. |
| Student's location at an NFC tap can't be sent | Saved and signed at the tap, sent later. |

The server accepts an offline upload only if it is signed by the student's
registered phone (active at that time), the QR code was valid when scanned,
it falls inside the check-in period (15 minutes for QR, 10 for phone taps),
and it is uploaded the same day (Philippine time). Each upload counts once,
and an existing check-in is never replaced. Offline saving needs a
registered phone; students without one still need internet.

### Setup

1. Run `migrations/20261103030000_offline_attendance.sql` in the SQL Editor.
2. Deploy the Edge Function in `functions/comptech-offline-attendance`:
   - with the Supabase CLI: `supabase functions deploy comptech-offline-attendance`
   - or in the dashboard: **Edge Functions → Deploy a new function → Via
     Editor**, name it `comptech-offline-attendance`, paste `index.ts`, and
     deploy. Keep **Verify JWT** on.
3. Rebuild the app (it adds Android code for the offline signatures).

Both phones should use automatic date and time: offline taps and scans are
timed by the phones' clocks, within a minute or two.

## BulSU student emails

`migrations/20261104000000_bulsu_student_email.sql` makes new student accounts
use an `@ms.bulsu.edu.ph` email. Run it in the SQL Editor like the others.

- Accounts created before the file is first run keep working with any email.
  That moment is saved in `comptech_email_policy.enforced_since`.
- Only student accounts are checked; professor accounts aren't affected.
- The database refuses a student sign-up with another email, and refuses
  turning an account with another email into a student, so the rule holds
  even outside the app. The registration screen shows the same rule.
- To change the domain: `update public.comptech_email_policy set domain = '...';`

## Archived classes

`migrations/20261104010000_archived_classes.sql` adds
`comptech_my_archived_class_ids()`. The student app uses it to leave archived
classes (`classes.status = 'archived'`, set by the professor dashboard) out of
every subject list: Home, Attendance & Classes, Letters, Scores and NFC. The
classes and their records aren't changed; restoring a class on the dashboard
brings it back. Until this file is run, nothing is hidden.

## Performance mode (professor NFC scanner)

`migrations/20261104020000_performance_points.sql` adds
`comptech_performance_points`, used by the scanner's **Performance** mode.
After a student's phone tap or card is scanned, a window shows the student
and lets the professor enter **hands-on** points. (Recitation is graded on
the professor dashboard.)

- The window has a **Hands-on column** picker listing the class's existing
  hands-on columns for the selected term (the class's `project` assessments,
  shown under Midterm / Final ACTIVITIES/Projects in the gradebook), with
  the student's current score in the chosen one. It starts on the column
  picked for the previous student.
- The scanner never creates columns. Add new ones on the professor
  dashboard; until a class has one for the term, scans say so and save
  nothing.
- The points replace the student's score in that column, so there's always
  one score per student and column. They're kept between 0 and the column's
  maximum.
- Each save notifies the student (a new score, or the score updated from
  the old value).
- Scores are saved as Draft, like the dashboard's own edits (with live
  scores, students see them right away).
- The professor can add an optional note. It goes into the score's
  `remarks`, after any earlier notes; leaving it empty changes nothing.
- Only the class's own professor can save points. A card is matched by its
  UID and the token written on it. There's no grace period: points can be
  given at any time.

## Class archived notification

`migrations/20261104030000_class_archived_notification.sql` notifies every
enrolled student when the professor dashboard archives a class. Tapping it
in the app opens Attendance & Classes, where the class is now listed under
Archived Classes. Restoring or editing a class sends nothing.

## New activity notification

`migrations/20261105010000_activity_notification.sql` notifies every
enrolled student when the professor dashboard adds an activity to a class
on Activities (a quiz, exam, class activity or hands-on activity: a new
`faculty_reminders` row). The notification shows the activity, its date and
time, and its description. Tapping it in the app opens Home on that class,
where the activity is listed under Upcoming Activities.

Edits and deletions send nothing, and neither does an activity dated before
today (Philippine time). No change is needed on the professor dashboard.

To set up, run the file in the SQL Editor after
`20261103010000_student_notifications.sql`.
