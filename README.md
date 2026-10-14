# Finance Tracker Mobile

Native Flutter version of the linked finance tracker dashboard. It keeps monthly income, expense, and balance totals, a 12-month trend, date-filtered category charts, and transaction notes/categories.

## Local use

Transactions and currency are written to app-local storage first. The app works without an account and without a network connection. Local-only data stays on that installation; clearing app data or changing devices will lose access to it.

## Supabase sync

1. Create a Supabase project and enable **Anonymous Sign-Ins** in Authentication settings.
2. Run [`supabase/schema.sql`](supabase/schema.sql) in the Supabase SQL editor.
3. Build with the project URL and anon/public key:

```sh
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
```

There is no sign-in screen. Supabase creates an anonymous identity on the first successful online sync. Its session is stored on that installation; a new device or cleared app data creates a different anonymous identity and cannot recover the old records. Records are saved locally first and uploaded when connectivity returns. RLS limits each anonymous identity to its own rows.

Without those two build-time values, the app remains local-only and shows **Device only** in its sync status.

## Build

Run `flutter pub get`, then use the build command above. The release APK is written to `build/app/outputs/flutter-apk/app-release.apk`.