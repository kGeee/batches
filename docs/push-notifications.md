# Push notifications

How a notification reaches a phone's lock screen:

1. A like, comment, tag, follow, share or added photo inserts a row in `notifications` (database triggers, `20261116000000_tags_and_notifications.sql`).
2. `private.queue_push` (trigger, `20261117000000_push_delivery.sql`) posts the row's id to the `push` edge function with pg_net. It skips people with no registered phone, and does nothing until the two vault secrets below exist.
3. `supabase/functions/push` calls `public.push_payload(id)`. That function runs the same visibility checks as the notifications page, as the recipient, so a tag on a batch that isn't shared with them yet is never pushed. It returns the alert text, the badge count and the recipient's device tokens.
4. The function sends to APNs (sandbox for builds run from Xcode, production for TestFlight and App Store), and deletes tokens Apple reports as dead.

The app registers its token through `register_device_token` once notifications are allowed, and stops showing its own local banners once it has a token, so nothing is shown twice.

## One-time setup

### 1. An APNs key (Apple Developer, 5 minutes)

- developer.apple.com → Certificates, IDs & Profiles → **Keys** → **+**. Name it "Batches push", tick **Apple Push Notifications service (APNs)**, choose Sandbox & Production, and download the `.p8` file. Apple lets you download it once, so keep it somewhere safe. Note the **Key ID** shown next to it.
- Identifiers → `com.kevingeorge.strewn` → make sure **Push Notifications** is ticked. Xcode's automatic signing usually does this on the next build, since `project.yml` now asks for the `aps-environment` entitlement.

### 2. Function secrets

```
supabase secrets set --project-ref exogbxkigwptelpbdaib \
  APNS_KEY_ID=<key id> \
  APNS_TEAM_ID=7CK43PG7GZ \
  APNS_PRIVATE_KEY="$(cat AuthKey_<key id>.p8)" \
  PUSH_WEBHOOK_SECRET=<the same random string as in step 3>
```

### 3. Database secrets (SQL editor)

```sql
select vault.create_secret('https://exogbxkigwptelpbdaib.supabase.co/functions/v1/push', 'push_function_url');
select vault.create_secret('<the same random string>', 'push_webhook_secret');
```

Generate the random string with `openssl rand -hex 32`.

### 4. Deploy

```
supabase db push --linked
supabase functions deploy push --project-ref exogbxkigwptelpbdaib
```

Build 12 calls `register_device_token`, so the migration has to be live before it ships.

## Checking it

- On a phone running a build from Xcode, allow notifications, then from another account like one of your photos. The alert should arrive within a couple of seconds.
- `select token, environment, updated_at from device_tokens` shows registered phones.
- `select * from net._http_response order by created desc limit 10` shows the database's calls to the function.
- Dashboard → Edge Functions → push → Logs shows APNs errors (`apns 403 InvalidProviderToken` means the key ID, team ID or key is wrong).
