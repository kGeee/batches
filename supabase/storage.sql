-- Storage tables and functions for Strewn's R2 plan. A draft, not a migration: not applied anywhere.
-- When R2 goes live, add it as the next file in supabase/migrations/. The plan behind it is
-- docs/storage-plan.md. Until then shared copies use the interim Supabase Storage bucket.
--
-- Image bytes live in Cloudflare R2, not in Supabase Storage:
--   media bucket  m/{owner_id}/{asset_id}/{tier}.heic|.jpg   shared copies, immutable
--   raw bucket    r/{owner_id}/{photo_id}.dng.enc             encrypted RAW backups (Plus only)
-- Rows store object keys, never full URLs, so the image host can change without a migration.
--
-- Supabase Edge Functions do the parts that need R2 credentials:
--   request-upload       calls begin_upload / begin_raw_backup as the user, returns presigned PUT URLs
--   finish-upload        HEADs each object in R2, then calls finish_upload / finish_raw_backup as service_role
--   storage-gc           every few minutes: expire_stale_uploads, claim_gc_batch, delete from R2, complete_gc
-- A Cloudflare Worker on the image domain checks the signatures from signed_media_paths.
--
-- Needs: pgcrypto (Supabase installs it in the extensions schema) and a Vault secret named
-- 'media_url_secret' shared with the Worker:
--   select vault.create_secret('<64 random hex chars>', 'media_url_secret');

-- One render of a photo: the recipe applied to its source, in every tier that was uploaded.
-- A new edit is a new asset, so object keys never change and can be cached forever.
create type media_tier as enum ('s', 'm', 'l', 'x', 'full', 'web');

-- Per-user plan and usage. Clients can read their own row; only service_role changes plan or limits
-- (after an App Store purchase is verified server side).
create table storage_accounts (
  user_id uuid primary key references profiles on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'plus')),
  shared_photo_limit int not null default 10000,
  full_res_allowed boolean not null default false,  -- may owners publish the 'full' tier
  raw_bytes_limit bigint not null default 0,        -- 0 = no RAW backup; Plus suggestion 250 GB
  shared_photos int not null default 0,             -- media_assets owned
  shared_bytes bigint not null default 0,           -- uploaded media_objects
  raw_bytes bigint not null default 0,              -- stored raw_backups
  updated_at timestamptz not null default now()
);

create table media_assets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles on delete cascade,
  -- sha256(source fingerprint + canonical recipe JSON + pipeline version), computed on the phone.
  -- The same render is uploaded once, however many piles or re-saves use it.
  render_hash text not null check (render_hash ~ '^[0-9a-f]{64}$'),
  pixel_width int not null check (pixel_width > 0),    -- size of the rendered image, after any crop
  pixel_height int not null check (pixel_height > 0),
  state text not null default 'uploading' check (state in ('uploading', 'ready')),
  created_at timestamptz not null default now(),
  unique (owner_id, render_hash)
);

create table media_objects (
  asset_id uuid not null references media_assets on delete cascade,
  tier media_tier not null,
  object_key text not null unique,
  content_type text not null,
  bytes bigint,                 -- set by finish_upload from R2's own HEAD, never by the client
  uploaded_at timestamptz,      -- null until finish_upload
  primary key (asset_id, tier)
);

alter table photos add column media_asset_id uuid references media_assets on delete set null;
create index photos_media_asset_idx on photos (media_asset_id);
-- Later, once the app reads media_asset_id: drop image_url, raw_url and original_url from photos.

create table raw_backups (
  photo_id uuid primary key references photos on delete cascade,
  owner_id uuid not null references profiles on delete cascade,
  object_key text not null unique,
  bytes bigint not null check (bytes > 0),
  ciphertext_sha256 text not null check (ciphertext_sha256 ~ '^[0-9a-f]{64}$'),
  -- Per-file AES-GCM key, wrapped on the phone by the user's key in iCloud Keychain.
  -- The server never sees an unwrapped key, so it can't read the RAW.
  wrapped_key text not null,
  key_id text not null,         -- which user key wrapped it, for rotation
  enc_alg text not null default 'AES-GCM-256',
  state text not null default 'uploading' check (state in ('uploading', 'stored')),
  created_at timestamptz not null default now()
);

-- Objects waiting to be deleted from R2. Old renders wait 7 days so viewers mid-scroll never
-- hit a missing file. No client access.
create table storage_gc_queue (
  id bigint generated always as identity primary key,
  bucket text not null check (bucket in ('media', 'raw')),
  object_key text not null,
  delete_after timestamptz not null default now() + interval '7 days',
  attempts int not null default 0,
  last_error text,
  claimed_at timestamptz
);
create index storage_gc_due_idx on storage_gc_queue (delete_after);

-- Row level security ---------------------------------------------------------------------------

alter table storage_accounts enable row level security;
alter table media_assets enable row level security;
alter table media_objects enable row level security;
alter table raw_backups enable row level security;
alter table storage_gc_queue enable row level security;  -- no policies: service_role only

create policy "read own storage account" on storage_accounts for select using (user_id = auth.uid());
create policy "read own media assets" on media_assets for select using (owner_id = auth.uid());
create policy "read own media objects" on media_objects for select
  using (exists (select 1 from media_assets a where a.id = asset_id and a.owner_id = auth.uid()));
create policy "read own raw backups" on raw_backups for select using (owner_id = auth.uid());
-- All writes go through the functions below. Viewers get image paths from signed_media_paths.

-- A photo may only point at a render its pile's owner made.
create or replace function check_photo_media_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.media_asset_id is not null and not exists (
      select 1 from media_assets a join collections c on c.id = new.collection_id
      where a.id = new.media_asset_id and a.owner_id = c.owner_id and a.state = 'ready') then
    raise exception 'media asset is not a finished render by this pile''s owner';
  end if;
  return new;
end $$;

create trigger photos_media_owner before insert or update of media_asset_id, collection_id on photos
  for each row execute function check_photo_media_owner();

-- Accounts and usage ---------------------------------------------------------------------------

create or replace function create_storage_account() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into storage_accounts (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

create trigger profiles_storage_account after insert on profiles
  for each row execute function create_storage_account();

create or replace function track_media_assets() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update storage_accounts set shared_photos = shared_photos + 1, updated_at = now() where user_id = new.owner_id;
  else
    update storage_accounts set shared_photos = shared_photos - 1, updated_at = now() where user_id = old.owner_id;
  end if;
  return null;
end $$;

create trigger media_assets_usage after insert or delete on media_assets
  for each row execute function track_media_assets();

-- Counts bytes once an object is confirmed, and queues its deletion when the row goes
-- (replaced render, deleted photo, deleted account: all cascade here).
create or replace function track_media_objects() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if tg_op = 'UPDATE' then
    if old.bytes is null and new.bytes is not null then
      select owner_id into owner from media_assets where id = new.asset_id;
      update storage_accounts set shared_bytes = shared_bytes + new.bytes, updated_at = now() where user_id = owner;
    end if;
    return null;
  end if;
  -- DELETE. The asset row may already be gone in a cascade, so the owner comes from the key.
  if old.bytes is not null then
    update storage_accounts set shared_bytes = greatest(0, shared_bytes - old.bytes), updated_at = now()
      where user_id = split_part(old.object_key, '/', 2)::uuid;
  end if;
  insert into storage_gc_queue (bucket, object_key) values ('media', old.object_key);
  return null;
end $$;

create trigger media_objects_usage after update or delete on media_objects
  for each row execute function track_media_objects();

-- When no photo points at a render any more, delete it (and through the cascade, queue its files).
create or replace function release_media_asset() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.media_asset_id is not null
     and (tg_op = 'DELETE' or new.media_asset_id is distinct from old.media_asset_id)
     and not exists (select 1 from photos where media_asset_id = old.media_asset_id) then
    delete from media_assets where id = old.media_asset_id;
  end if;
  return null;
end $$;

create trigger photos_release_media after update of media_asset_id or delete on photos
  for each row execute function release_media_asset();

create or replace function track_raw_backups() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if old.state = 'uploading' and new.state = 'stored' then
      update storage_accounts set raw_bytes = raw_bytes + new.bytes, updated_at = now() where user_id = new.owner_id;
    end if;
    return null;
  end if;
  if old.state = 'stored' then
    update storage_accounts set raw_bytes = greatest(0, raw_bytes - old.bytes), updated_at = now()
      where user_id = old.owner_id;
  end if;
  -- RAW goes at once: the user asked for it gone, and R2 IA bills 30 days either way.
  insert into storage_gc_queue (bucket, object_key, delete_after) values ('raw', old.object_key, now());
  return null;
end $$;

create trigger raw_backups_usage after update or delete on raw_backups
  for each row execute function track_raw_backups();

-- Uploads --------------------------------------------------------------------------------------

-- Step 1, called as the user (through request-upload). Checks ownership and quota, and returns
-- the keys still to upload. existing = true means this exact render is already stored: the
-- client skips the upload and calls finish_upload's sibling attach_media instead.
create or replace function begin_upload(
  p_photo_id uuid, p_render_hash text, p_width int, p_height int, p_tiers media_tier[])
returns table (asset_id uuid, existing boolean, tier media_tier, object_key text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  acct storage_accounts;
  a media_assets;
  t media_tier;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from photos p join collections c on c.id = p.collection_id
                 where p.id = p_photo_id and c.owner_id = uid) then
    raise exception 'not your photo';
  end if;

  select * into a from media_assets where owner_id = uid and render_hash = p_render_hash;
  if found and a.state = 'ready' then
    return query select a.id, true, null::media_tier, null::text;
    return;
  end if;

  select * into acct from storage_accounts where user_id = uid;
  if 'full' = any (p_tiers) and not acct.full_res_allowed then
    raise exception 'full resolution copies need Strewn Plus';
  end if;
  if a.id is null then
    if acct.shared_photos >= acct.shared_photo_limit then
      raise exception 'photo limit reached';
    end if;
    insert into media_assets (owner_id, render_hash, pixel_width, pixel_height)
      values (uid, p_render_hash, p_width, p_height) returning * into a;
  end if;

  foreach t in array p_tiers loop
    insert into media_objects (asset_id, tier, object_key, content_type)
      values (a.id, t,
              format('m/%s/%s/%s.%s', uid, a.id, t, case when t = 'web' then 'jpg' else 'heic' end),
              case when t = 'web' then 'image/jpeg' else 'image/heic' end)
      on conflict on constraint media_objects_pkey do nothing;
  end loop;

  return query
    select a.id, false, o.tier, o.object_key from media_objects o
    where o.asset_id = a.id and o.uploaded_at is null;
end $$;

-- Step 2, service_role only (finish-upload, after R2 HEAD confirms each object).
-- p_sizes is {"s": 12345, "m": 56789, ...} from R2, not from the client.
-- Marks the render ready and swaps the photo onto it in one transaction.
create or replace function finish_upload(p_asset_id uuid, p_photo_id uuid, p_sizes jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare a media_assets;
begin
  update media_objects o set bytes = (p_sizes ->> o.tier::text)::bigint, uploaded_at = now()
    where o.asset_id = p_asset_id and o.uploaded_at is null and p_sizes ? o.tier::text;
  if exists (select 1 from media_objects where asset_id = p_asset_id and uploaded_at is null) then
    raise exception 'not every tier is uploaded yet';
  end if;
  update media_assets set state = 'ready' where id = p_asset_id returning * into a;
  update photos set media_asset_id = a.id, pixel_width = a.pixel_width, pixel_height = a.pixel_height
    where id = p_photo_id;
end $$;

-- For a render that already exists (dedupe), called as the user.
create or replace function attach_media(p_photo_id uuid, p_asset_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a media_assets;
begin
  select * into a from media_assets where id = p_asset_id and owner_id = auth.uid() and state = 'ready';
  if not found then raise exception 'no such render'; end if;
  update photos p set media_asset_id = a.id, pixel_width = a.pixel_width, pixel_height = a.pixel_height
    from collections c
    where p.id = p_photo_id and c.id = p.collection_id and c.owner_id = auth.uid();
end $$;

-- RAW backup, called as the user. Returns the key to upload to (multipart, presigned by request-upload).
create or replace function begin_raw_backup(
  p_photo_id uuid, p_bytes bigint, p_ciphertext_sha256 text, p_wrapped_key text, p_key_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  acct storage_accounts;
  k text := format('r/%s/%s.dng.enc', auth.uid(), p_photo_id);
begin
  if uid is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from photos p join collections c on c.id = p.collection_id
                 where p.id = p_photo_id and c.owner_id = uid) then
    raise exception 'not your photo';
  end if;
  select * into acct from storage_accounts where user_id = uid;
  if acct.raw_bytes + p_bytes > acct.raw_bytes_limit then
    raise exception 'RAW backup needs Strewn Plus, or the RAW backup limit is reached';
  end if;
  insert into raw_backups (photo_id, owner_id, object_key, bytes, ciphertext_sha256, wrapped_key, key_id)
    values (p_photo_id, uid, k, p_bytes, p_ciphertext_sha256, p_wrapped_key, p_key_id)
    on conflict (photo_id) do update set bytes = excluded.bytes, ciphertext_sha256 = excluded.ciphertext_sha256,
      wrapped_key = excluded.wrapped_key, key_id = excluded.key_id, state = 'uploading'
    where raw_backups.state = 'uploading';
  return k;
end $$;

-- service_role only, after R2 HEAD shows the expected size.
create or replace function finish_raw_backup(p_photo_id uuid, p_bytes bigint) returns void
language sql security definer set search_path = public as $$
  update raw_backups set state = 'stored', bytes = p_bytes where photo_id = p_photo_id and state = 'uploading';
$$;

-- Viewing --------------------------------------------------------------------------------------

-- Signed paths for every photo in a pile the caller may see. The Worker recomputes
-- hmac(path || ':' || e) and checks e hasn't passed. Expiry is the end of the next UTC day, so a
-- URL stays the same all day and the phone's cache keeps working.
-- Client URL: https://<image host><path>?e=<expires>&s=<sig>
create or replace function signed_media_paths(p_collection_id uuid)
returns table (photo_id uuid, tier media_tier, path text, expires bigint, sig text)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  c collections;
  secret text;
  e bigint := extract(epoch from date_trunc('day', now() at time zone 'utc') + interval '2 days')::bigint;
begin
  select * into c from collections where id = p_collection_id;
  if not found or not can_view_collection(c) then return; end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'media_url_secret';

  return query
    select p.id, o.tier, '/' || o.object_key, e,
           encode(hmac('/' || o.object_key || ':' || e, secret, 'sha256'), 'hex')
    from photos p
    join media_objects o on o.asset_id = p.media_asset_id and o.uploaded_at is not null
    where p.collection_id = p_collection_id
      and (o.tier <> 'full' or exists (            -- full only when the owner allows downloads
            select 1 from storage_accounts s where s.user_id = c.owner_id and s.full_res_allowed));
end $$;

-- Garbage collection (storage-gc Edge Function, service_role) ----------------------------------

create or replace function claim_gc_batch(p_limit int default 500)
returns setof storage_gc_queue
language sql security definer set search_path = public as $$
  update storage_gc_queue q set claimed_at = now(), attempts = attempts + 1
  where q.id in (
    select id from storage_gc_queue
    where delete_after <= now() and (claimed_at is null or claimed_at < now() - interval '15 minutes')
    order by delete_after limit p_limit
    for update skip locked)
  returning q.*;
$$;

-- Renders whose upload never finished (app killed, user gave up) stop counting toward the photo
-- limit after a day. Their objects, if any arrived, are queued for deletion by the cascade.
create or replace function expire_stale_uploads() returns int
language sql security definer set search_path = public as $$
  with gone as (
    delete from media_assets where state = 'uploading' and created_at < now() - interval '1 day' returning 1)
  select count(*)::int from gone;
$$;

-- p_failed: [{"id": 1, "error": "..."}] for keys R2 refused; the rest are removed from the queue.
create or replace function complete_gc(p_done bigint[], p_failed jsonb default '[]') returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from storage_gc_queue where id = any (p_done);
  update storage_gc_queue q set claimed_at = null, last_error = f ->> 'error'
    from jsonb_array_elements(p_failed) f where q.id = (f ->> 'id')::bigint;
end $$;

-- Who may call what ----------------------------------------------------------------------------

revoke execute on function begin_upload(uuid, text, int, int, media_tier[]),
                           attach_media(uuid, uuid),
                           begin_raw_backup(uuid, bigint, text, text, text),
                           signed_media_paths(uuid),
                           finish_upload(uuid, uuid, jsonb),
                           finish_raw_backup(uuid, bigint),
                           claim_gc_batch(int),
                           complete_gc(bigint[], jsonb),
                           expire_stale_uploads()
  from public, anon;
grant execute on function begin_upload(uuid, text, int, int, media_tier[]),
                          attach_media(uuid, uuid),
                          begin_raw_backup(uuid, bigint, text, text, text),
                          signed_media_paths(uuid)
  to authenticated;
revoke execute on function finish_upload(uuid, uuid, jsonb), finish_raw_backup(uuid, bigint),
                           claim_gc_batch(int), complete_gc(bigint[], jsonb), expire_stale_uploads()
  from authenticated;
grant execute on function finish_upload(uuid, uuid, jsonb), finish_raw_backup(uuid, bigint),
                          claim_gc_batch(int), complete_gc(bigint[], jsonb), expire_stale_uploads()
  to service_role;

-- Public web share pages call signed_media_paths through an Edge Function as service_role, which
-- needs its own check that the pile is public, since can_view_collection sees no auth.uid() there.
-- Schedule storage-gc with pg_cron + pg_net, or a Supabase scheduled function, every 5 minutes.
