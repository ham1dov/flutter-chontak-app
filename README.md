# Finance Tracker Mobile

Native Flutter version of the linked finance tracker dashboard. It keeps monthly income, expense, and balance totals, a 12-month trend, date-filtered category charts, and transaction notes/categories.

## How data is stored

The app is **offline-first**. Every change is written to app-local storage first, so it works with no account and no network.

- **Signed out:** records stay on the device only.
- **Signed in:** records are also synced with your Supabase (Postgres) account. Whenever the device is online (on app start, when the connection returns, when the app is reopened, or after each change) the app
  1. downloads your cloud records into local storage, and
  2. uploads every local record the cloud is missing or has an older version of.
  The newest edit of a record wins. Nothing is ever deleted from local storage by a sync, and a failed sync is retried automatically.
- **First sign-in:** records you created while signed out or offline are adopted into your account and uploaded.
- **Several accounts on one device:** each account has its own local copy. Signing out keeps it on the device (it comes back when you sign in again) and a different account never sees it.

## Supabase setup

1. Create a Supabase project and run [`supabase/new_project_schema.sql`](supabase/new_project_schema.sql) in the SQL editor (it is safe to run twice). It creates the `transactions` and `profiles` tables, Row Level Security, and protection against an old offline edit overwriting a newer one. `supabase/schema.sql` is the older, smaller version and is not needed on a fresh project.
2. **Authentication → Providers → Email:** enable it. (Keep "Confirm email" on if you want verified addresses; the app tells the user to open the confirmation link.)
3. **Authentication → Providers → Google:** enable it and paste a Google OAuth *Web application* client ID and secret ([Supabase guide](https://supabase.com/docs/guides/auth/social-login/auth-google)). In Google Cloud Console add the callback URL shown by Supabase (`https://YOUR_PROJECT.supabase.co/auth/v1/callback`) as an authorized redirect URI.
4. **Authentication → URL Configuration → Redirect URLs:** add `com.chontak.financetracker://login-callback/`.
5. Anonymous sign-ins are no longer used and can be turned off.
6. Build with the project URL and anon/public key:

```sh
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
```

Row Level Security limits each account to its own rows. Without those two build-time values the app stays local-only and shows **Device only**.

The auth callback deep link (`com.chontak.financetracker://login-callback/`) is declared in `android/app/src/main/AndroidManifest.xml` and `_authRedirect` in `lib/main.dart`; change all three places together if you rename it.

## Build

Run `flutter pub get`, then use the build command above. The release APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

## Tests

`flutter test test/finance_entry_test.dart`
