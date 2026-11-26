# CiTracker (This is a Copy of the Original Shared Repository with other thesis member)

Student mobile app of **CiTracker: An Integrated Classroom Attendance and Student Performance Management System**, a capstone thesis project by a BIT Computer Technology team at Bulacan State University, College of Industrial Technology.

Students check in to class by tapping their phone or an assigned NFC card on the professor's scanner, or by scanning the professor's QR code. Faculty accounts open a built-in NFC scanner for attendance and hands-on scoring.

## Download

Android APKs are in the [`apk/`](apk) folder (version 1.0.0, Android 7.0 or newer):

- [`CiTracker-1.0.0-arm64-v8a.apk`](apk/CiTracker-1.0.0-arm64-v8a.apk) – for almost all current phones
- [`CiTracker-1.0.0-armeabi-v7a.apk`](apk/CiTracker-1.0.0-armeabi-v7a.apk) – for older 32-bit phones

Open the file's page, click **Download raw file**, then open it on the phone and allow installing from this source. These builds are signed with a development key, not a Play Store key.

## Features

- NFC attendance (Tap Phone using Host Card Emulation, or an assigned NFC card) and QR code attendance
- Each account is bound to one registered phone to prevent proxy check-ins
- Offline check-in: signed and saved on the phone, uploaded automatically once back online
- Location logging with an on-campus check
- Enrolled classes, attendance history, live scores and grades, excuse letters, and notifications
- Professor NFC scanner for attendance and hands-on performance points
- Light and dark mode

## Tech stack

- Flutter and Dart, with Kotlin for the Android NFC features
- Supabase: PostgreSQL, Auth, Realtime, Storage, and Edge Functions (TypeScript)

## Project layout

- `lib/` – the Flutter app
- `android/app/src/main/kotlin/` – phone key and NFC card emulation
- `supabase/migrations/` – database functions and tables
- `supabase/functions/` – Edge Functions
- `docs/` – thesis flowcharts, wireframes and test documents

## Running it

```bash
flutter pub get
flutter run
```

NFC features need an Android phone with NFC. The app connects to the team's Supabase project; to run your own backend, change the URL and publishable key in `lib/main.dart` and apply the migrations in `supabase/migrations/`.
