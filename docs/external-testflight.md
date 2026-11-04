# Getting Batches to external TestFlight

Written November 3, 2026, updated for build 7 (1.0). Internal testing (up to 100 people on your App Store Connect team) already works. External testing lets up to 10,000 people in by email or a public link, but each new version's first build goes through Apple's Beta App Review, usually a day or two.

## What's ready

- Bundle ID `com.kevingeorge.strewn`, signed by your team, version and build numbers in `project.yml` (build 7).
- Export compliance declared (`ITSAppUsesNonExemptEncryption` = NO), so no encryption paperwork.
- Privacy manifest (`Strewn/Resources/PrivacyInfo.xcprivacy`): no tracking; email, name, user ID and photos collected only to run the app.
- Sign in with Apple and email sign-in, against your live Supabase project, with the group-batch database change applied.
- Camera tab hidden; the photo-access prompt explains why the app asks.
- **Delete account** (guideline 5.1.1(v)): Account → Delete account, behind typing your handle. It removes your shared copies from storage, then calls `delete_account()`, which deletes the photos you added to friends' batches and your auth user; the rest cascades.
- **Report and block** (guideline 1.2): ⋯ on someone's batch (Report batch, Block), Report on any photo that isn't yours (in its menu and in the photo viewer), and ⋯ on someone's desk (Report, Block / Unblock). Account → Blocked lists who you've blocked. Blocking works both ways in the database: neither person sees the other's batches or added photos, follows and shares between them go, and they can't be re-made.
- **Contact and privacy policy** in the account sheet, from `SUPPORT_EMAIL` and `PRIVACY_POLICY_URL` (the email is set in `Config.local.xcconfig`; the policy row appears once the URL is set). The policy itself is `site/privacy.html`.
- **Password sign-in** for the App Review account only, behind "Sign in with a password" under the email field.

All of it is in `supabase/migrations/20261104000000_safety.sql`, checked by `supabase/tests/database/safety.test.sql` (21 checks, passing on a local Postgres).

## What to do, in order

### 1. Put the safety migration live (5 minutes)

Build 7 needs it: without it, delete account, report and block fail with an error.

```
supabase db push --linked
supabase/tests/run-linked.sh supabase/tests/database/safety.test.sql supabase/tests/database/group_piles.test.sql
```

Then check on reports daily: Table Editor → `reports`, newest first, `status = 'open'`. Apple expects objectionable content gone within 24 hours. When you act, set `status` to `actioned` (or `dismissed`).

### 2. Sign-in that works for testers and the reviewer (setup, an hour or two)

- **Turn on Apple in Supabase** if it isn't yet: Authentication → Providers → Apple, client ID `com.kevingeorge.strewn`.
- **Set up custom email (SMTP)** in Supabase. The built-in mailer sends only a few emails an hour and only a link, so a wave of testers will run into the limit. Resend, Postmark or SendGrid all have free tiers. Then turn on the templates in `supabase/config.toml` so emails carry a six-digit code (they already say "Batches").
- **The review account.** In Supabase: Authentication → Users → Add user → Create new user, an email such as `review@` your domain, a strong password, "Auto confirm" on. Sign in with it once on your phone ("Sign in with a password"), pick a handle, and make two or three batches, one shared with your own account, so the reviewer sees the app populated. Give Apple that email and password under Beta App Review Information.

### 3. Privacy policy (done)

Live at https://batches-app-topaz.vercel.app/privacy, deployed from `site/` to the Vercel project `batches-app` (redeploy with `vercel deploy --prod` from `site/`). `PRIVACY_POLICY_URL` is set in `Config.local.xcconfig`, so build 7 links to it from the account sheet. Paste the same URL into App Store Connect. It lists kegeorge246@gmail.com as the contact; change it there and in `SUPPORT_EMAIL` if you'd rather use a separate address.

### 4. App Store Connect (setup, under an hour)

- App Information → Name: **Batches** (testers see this name, not the one inside the app). If it's taken, something like "Batches: Shared Albums".
- App Privacy: the privacy policy URL, and data types matching the policy (contact info: email; user content: photos; identifiers: user ID; all "app functionality", none for tracking).
- TestFlight → Test Information: a short description of what to try, a feedback email, and your contact details. Under Beta App Review Information, the review account, and a note: "Sign in with a password under the email field. Report and block are under ⋯ on any friend's batch or profile; Delete account is in Account."
- Create an external group, add build 7, and submit it for review. Once approved, turn on the **public link** if you want people to join without you entering their emails.

### 5. Before inviting people (an hour)

- Try a group batch end to end on two real phones: share a batch with "Can add photos" on, add a photo from the other phone, remove it from the owner's phone. This is the one flow not yet tested with two real accounts.
- On the second phone, report a photo and block the first account, then check the `reports` row and that each side's batches disappeared for the other. Unblock afterwards.
- Delete a throwaway account and check its batches and files are gone (Storage → media has no folder for its user ID).
- Upgrade Supabase to Pro ($25 a month) if you expect more than a few dozen testers. The free plan's database pauses after a week without activity and has a 1 GB storage cap, about 3,000 shared photos.

### 6. While it's out

- TestFlight builds expire after 90 days, so upload a new one at least every couple of months. Bump `CURRENT_PROJECT_VERSION` in `project.yml` each time.
- Later builds of the same version usually skip full review; a new version number (1.1) goes through it again.
- Crash reports and screenshots testers send show up in App Store Connect under TestFlight → Feedback.

## Rough timeline

| | Time |
| --- | --- |
| Safety migration live | 5 minutes |
| SMTP, review account, Apple provider | an hour or two |
| Privacy policy hosted and App Store Connect forms | under an hour |
| Two-phone test | an hour |
| Beta App Review | usually one or two days |

So external testers in about two days, most of it waiting on Apple.
