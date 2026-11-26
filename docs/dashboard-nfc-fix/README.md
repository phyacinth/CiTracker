# Fix: NFC card scanning on the professor dashboard website

On the dashboard website (Chrome on Android):

- **Attendance** card scans end in **Card could not be verified**, while the
  CompTech app's professor scanner verifies the same card.
- **Performance** scores are never saved: **Save Record** only keeps them on
  that page ("performance drafts in this session"), so they don't reach the
  gradebook. The scanned student also shows as the card's ID, not their name.

This folder makes the website's NFC card scanner work like the app's.

## What changes

| | Before | After (same as the app) |
| --- | --- | --- |
| Attendance scan backend | `faculty-nfc-attendance` | `nfc-attendance`, the function the app uses |
| Card accepted | Any text on the card, used whole as the token | One UTF-8 Text record: `COMPTECH:NFC:CARD:V1:` + 64 hex characters, as written by the student app |
| After an attendance scan | Waits for the student's phone | Same, through `nfc-attendance` |
| Performance scan | Went through the attendance check | Only identifies the student (name and student ID). Records no attendance; the student's phone isn't needed |
| Performance score | Kept on the page only | Saved to the gradebook through `comptech_performance_points` (the app's function), as Draft, and the student is notified |
| Where the score goes | A "Hands-On index" number | A picker of the class's **existing** hands-on columns for the term, with the student's current score. Saving **replaces** that score |
| Rubric | Fixed: 4 sliders, 5 points each | **Editable**: rename, add (up to 10) or remove criteria, set each one's maximum. Kept on that device per class |
| Rubric total → column | Not saved | Scaled to the column's maximum: 15/20 becomes 75/100. The breakdown is added to the score's note |
| Errors | Hidden behind the class-timer message | The real reason, in the same words as the app |

Only the NFC scanner in the class session window changes (the `ActiveClass`
component's card scanning and its Performance card). Starting and ending
classes, the QR code, the live roster, Records, Activities, OMR, login and
password recovery aren't touched.

Checked here: the file parses, the patch applies cleanly to the copy it was
made from, and a TypeScript type check finds no new errors (the dashboard
already has 12 type errors elsewhere, unchanged).

| File | What it is |
| --- | --- |
| `App.tsx` | The dashboard's `App.tsx` with the changes. Made from the latest copy (5 Nov 2026), which already has the attendance change; this adds the Performance card. |
| `App.tsx.patch` | The Performance card change as a patch, for a dashboard `App.tsx` that has changed since. It assumes the attendance change is already in. |
| `background.md` | Why card scans failed, for the dashboard team. |
| `faculty-nfc-attendance/index.ts` | Optional: a fixed version of the dashboard's own function. The website no longer uses it for card scans. |

## Before you start (Supabase)

Run the latest `supabase/migrations/20261104020000_performance_points.sql`
from the student app's repo in the SQL Editor, if it hasn't been run since the
hands-on column picker was added. Performance mode on both the app and the
website uses it. Nothing else changes in Supabase.

## Step 1: Update the dashboard website

1. Open the dashboard project and create a branch, e.g. `fix-nfc-scanner`.
2. Put the change in, either way (the attendance part is already in the
   5 Nov copy; this adds the Performance card):
   - **Replace** `src/App.tsx` with `App.tsx` from this folder, if the
     dashboard's `App.tsx` hasn't changed since the copy it was made from; or
   - **Apply the patch** from the project folder:
     `git apply path/to/App.tsx.patch`
     (if it says it doesn't apply, the file has changed; send it over and the
     change can be redone on the new version).
3. Build it: `npm run build`.
4. Commit and push the branch. Vercel makes a **preview** link; test there
   (Step 2) before merging to the live site (ci-tracker.online).

## Step 2: Test

**Attendance**

1. On the professor's phone, open the dashboard (the preview link) in Chrome,
   start the class, and tap **Scan student card**.
2. On the student's phone, open **NFC Attendance → Use Card**, select the
   class, and tap **Enable Attendance Readiness**.
3. Hold the student's card to the professor's phone. The website shows
   "Waiting for the student's phone…", then **Attendance recorded
   successfully**, and the student appears in the live roster.

**Performance**

1. In the class session, switch to **Performance**, pick the term, and tap
   **Scan student card**. Hold a student's card to the phone (the student
   doesn't need to do anything).
2. The card shows the student's **name and student ID**, and a **Hands-on
   column** picker with their current score.
3. Optional: tap **Edit rubric** to rename criteria, change maximums, or add
   or remove criteria, then **Done editing**.
4. Set the sliders and tap **Save to gradebook**. The message shows the saved
   score, e.g. "75 / 100 in Midterm Project 1".
5. On the dashboard's **Records → Gradebook (Summary)**, that column shows the
   new score (reload the page if Records was already open), and the student
   gets a notification.

If the picker says the class has no hands-on columns for the term: add one in
Records → Midterm/Final ACTIVITIES/Projects and type a score into it once
(a column is only saved to the database after its first score), then scan
again.

## What professors and students need to know

- **Attendance** card scans are confirmed by the student's own phone: the
  student must have **NFC Attendance → Use Card** open, with the class
  selected and **Enable Attendance Readiness** on, within 30 minutes of the
  class starting.
- **Performance** card scans only need the card. They record no attendance
  and have no time limit.
