-- Push delivery for notifications.
--
--   new row in notifications
--     -> private.queue_push (trigger) posts {id} to the `push` edge function with pg_net, which
--        sends only after the inserting transaction commits
--     -> the function calls public.push_payload(id) as service_role, and sends to APNs
--
-- Nothing here can make writing a notification fail: if the vault secrets aren't set yet, or pg_net
-- errors, the notification is still stored and shows in the app.
--
-- Setup, once per project (the function URL and a random secret shared with the function):
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/push', 'push_function_url');
--   select vault.create_secret('<random>', 'push_webhook_secret');

create extension if not exists pg_net with schema extensions;

-- Registering a device token -------------------------------------------------------------------

-- A phone keeps its APNs token across sign-outs, so the row may still belong to the last account
-- used on it. Row level security (rightly) won't let one user rewrite another's row, so this hands
-- the token to whoever registers it now. Tokens are 32+ random bytes from Apple, so knowing one
-- means holding the device.
create or replace function public.register_device_token(p_token text, p_environment text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  insert into device_tokens (token, user_id, environment, updated_at)
  values (p_token, auth.uid(), p_environment, now())
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
end $$;
revoke execute on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;

-- What to push -----------------------------------------------------------------------------------

-- The alert for one notification, or null when it shouldn't be pushed (yet). Runs the same checks
-- as the "read own notifications" policy, as the recipient, so tagging someone on a batch that
-- isn't shared with them doesn't announce it. The wording matches the app's local banners
-- (PushNotifications.deliverLocalBannerIfNeeded).
create or replace function public.push_payload(p_notification uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n notifications;
  actor_name text;
  actor_handle text;
  batch_title text;
  text_body text;
  quoted text;
  unread int;
  devices jsonb;
begin
  select * into n from notifications where id = p_notification;
  if n.id is null or n.read_at is not null then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('token', token, 'environment', environment)), '[]'::jsonb)
    into devices from device_tokens where user_id = n.recipient_id;
  if devices = '[]'::jsonb then
    return null;
  end if;

  -- Act as the recipient for the visibility checks below (auth.uid() reads these settings).
  perform set_config('request.jwt.claims', jsonb_build_object('sub', n.recipient_id, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', n.recipient_id::text, true);

  if private.blocked_between(n.recipient_id, n.actor_id)
     or (n.collection_id is not null and not exists (
           select 1 from collections c where c.id = n.collection_id and private.can_view_collection(c)))
     or (n.photo_id is not null and not private.can_view_photo(n.photo_id)) then
    return null;
  end if;

  select display_name, handle into actor_name, actor_handle from profiles where id = n.actor_id;
  actor_name := coalesce(actor_name, 'Someone');
  select title into batch_title from collections where id = n.collection_id;
  quoted := case when length(n.body) > 180 then left(n.body, 179) || '…' else n.body end;

  text_body := case n.kind
    when 'photo_like' then actor_name || ' liked your photo'
    when 'photo_comment' then actor_name || ' commented: ' || coalesce(quoted, '')
    when 'comment_mention' then actor_name || ' mentioned you: ' || coalesce(quoted, '')
    when 'photo_tag' then actor_name || ' tagged you in ' || coalesce(batch_title, 'a photo')
    when 'batch_shared' then
      case when n.body = 'can_add'
        then actor_name || ' invited you to add ' || coalesce('photos to ' || batch_title, 'to a batch')
        else actor_name || ' shared ' || coalesce(batch_title, 'a batch') || ' with you' end
    when 'photo_added' then
      actor_name || ' added ' || case when coalesce(n.body, '1') = '1' then 'a photo' else n.body || ' photos' end
        || ' to ' || coalesce(batch_title, 'your batch')
    when 'follow' then actor_name || ' started following you'
    else actor_name || ' sent you something'
  end;

  -- The badge counts what the notifications page would show as unread.
  select count(*) into unread
    from notifications u
   where u.recipient_id = n.recipient_id
     and u.read_at is null
     and not private.blocked_between(n.recipient_id, u.actor_id)
     and (u.collection_id is null or exists (
           select 1 from collections c where c.id = u.collection_id and private.can_view_collection(c)))
     and (u.photo_id is null or private.can_view_photo(u.photo_id));

  return jsonb_build_object(
    'title', 'Batches',
    'body', text_body,
    'badge', unread,
    'thread', n.collection_id,
    'notification_id', n.id,
    'collection_id', n.collection_id,
    'photo_id', n.photo_id,
    'actor_handle', actor_handle,
    'devices', devices);
end $$;
revoke execute on function public.push_payload(uuid) from public, anon, authenticated;
grant execute on function public.push_payload(uuid) to service_role;

-- Handing new notifications to the function --------------------------------------------------------

create or replace function private.queue_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  url text;
  secret text;
begin
  -- Skip the HTTP call entirely for people with no registered phone.
  if not exists (select 1 from device_tokens where user_id = new.recipient_id) then
    return null;
  end if;
  select decrypted_secret into url from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if url is null or secret is null then
    return null;
  end if;
  perform net.http_post(
    url := url,
    body := jsonb_build_object('id', new.id),
    headers := jsonb_build_object('content-type', 'application/json', 'authorization', 'Bearer ' || secret),
    timeout_milliseconds := 5000);
  return null;
exception when others then
  raise warning 'queue_push %: %', new.id, sqlerrm;
  return null;
end $$;
revoke execute on function private.queue_push() from public, anon, authenticated;

create trigger notifications_push after insert on notifications
  for each row execute function private.queue_push();
