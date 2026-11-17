-- Tagging people on photos, @handle mentions in comments, notifications, and device push tokens.
--
-- Additive, so older builds keep working: they ignore tables they don't know, and collections /
-- photos columns are unchanged.
--
-- Privacy rules live here in row level security:
--   - Tags on a photo are readable only if you can view that photo and neither the tagged person
--     nor the tagger is across a block from you.
--   - Only the batch owner or the contributor who added a photo can tag people on it (never across
--     a block). Anyone tagged can always remove their own tag, as can the tagger, photo adder and
--     batch owner.
--   - Notifications are written only by database triggers (clients can't forge them), readable only
--     by their recipient while the underlying batch/photo is visible to them and not across a block,
--     and clients can only mark their own notifications read or delete them.

-- Photo tags -----------------------------------------------------------------------------------

create or replace function private.can_tag_photo(photo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from photos p join collections c on c.id = p.collection_id
    where p.id = photo
      and (c.owner_id = auth.uid()
           or (p.added_by = auth.uid() and private.can_add_to_collection(c.id))));
$$;
revoke execute on function private.can_tag_photo(uuid) from public, anon;
grant execute on function private.can_tag_photo(uuid) to authenticated;

create table photo_tags (
  photo_id uuid not null references photos on delete cascade,
  user_id uuid not null references profiles on delete cascade,
  tagged_by uuid not null default auth.uid() references profiles on delete cascade,
  -- Normalized position on the full-frame photo (0..1 from top-left); null tags without a pin.
  x double precision,
  y double precision,
  created_at timestamptz not null default now(),
  primary key (photo_id, user_id),
  check ((x is null) = (y is null) and (x is null or (x between 0 and 1 and y between 0 and 1)))
);
create index photo_tags_user_idx on photo_tags (user_id, created_at desc);
create index photo_tags_tagged_by_idx on photo_tags (tagged_by);

alter table photo_tags enable row level security;

create policy "read tags on visible photos" on photo_tags for select to authenticated
  using (
    private.can_view_photo(photo_id)
    and (user_id = (select auth.uid()) or not private.blocked_between((select auth.uid()), user_id))
    and (tagged_by = (select auth.uid()) or not private.blocked_between((select auth.uid()), tagged_by)));

create policy "tag people on own photos" on photo_tags for insert to authenticated
  with check (
    tagged_by = (select auth.uid())
    and private.can_tag_photo(photo_id)
    and not private.blocked_between((select auth.uid()), user_id)
    and not exists (
      select 1 from photos p join collections c on c.id = p.collection_id
      where p.id = photo_id and private.blocked_between(c.owner_id, user_id)));

create policy "move tags on own photos" on photo_tags for update to authenticated
  using (private.can_tag_photo(photo_id))
  with check (
    tagged_by = (select auth.uid())
    and private.can_tag_photo(photo_id)
    and not private.blocked_between((select auth.uid()), user_id)
    and not exists (
      select 1 from photos p join collections c on c.id = p.collection_id
      where p.id = photo_id and private.blocked_between(c.owner_id, user_id)));

-- The tagged person can always untag themselves; the tagger, photo adder and batch owner can too.
create policy "remove photo tags" on photo_tags for delete to authenticated
  using (
    user_id = (select auth.uid())
    or tagged_by = (select auth.uid())
    or exists (
      select 1 from photos p join collections c on c.id = p.collection_id
      where p.id = photo_id and (c.owner_id = (select auth.uid()) or p.added_by = (select auth.uid()))));

revoke all on photo_tags from anon, authenticated;
grant select, delete on photo_tags to authenticated;
grant insert (photo_id, user_id, tagged_by, x, y), update (tagged_by, x, y) on photo_tags to authenticated;

-- Notifications --------------------------------------------------------------------------------

create table notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references profiles on delete cascade,
  actor_id uuid not null references profiles on delete cascade,
  kind text not null check (kind in (
    'photo_like',
    'photo_comment',
    'comment_mention',
    'photo_tag',
    'batch_shared',
    'photo_added',
    'follow'
  )),
  collection_id uuid references collections on delete cascade,
  photo_id uuid references photos on delete cascade,
  comment_id uuid references photo_comments on delete cascade,
  body text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  check (recipient_id <> actor_id)
);
create index notifications_recipient_idx on notifications (recipient_id, created_at desc);
create index notifications_unread_idx on notifications (recipient_id) where read_at is null;
create index notifications_actor_idx on notifications (actor_id);
create index notifications_collection_idx on notifications (collection_id);
create index notifications_photo_idx on notifications (photo_id);
create index notifications_comment_idx on notifications (comment_id);

alter table notifications enable row level security;

-- A notification on a private or unshared batch stays hidden until its recipient can actually view
-- that batch and photo, so tagging someone before sharing never leaks a private batch.
create policy "read own notifications" on notifications for select to authenticated
  using (
    recipient_id = (select auth.uid())
    and not private.blocked_between((select auth.uid()), actor_id)
    and (collection_id is null or exists (
      select 1 from collections c where c.id = collection_id and private.can_view_collection(c)))
    and (photo_id is null or private.can_view_photo(photo_id)));

create policy "mark own notifications read" on notifications for update to authenticated
  using (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));

create policy "delete own notifications" on notifications for delete to authenticated
  using (recipient_id = (select auth.uid()));

revoke all on notifications from anon, authenticated;
grant select, delete on notifications to authenticated;
grant update (read_at) on notifications to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table notifications;
  end if;
end $$;

-- Notification triggers ------------------------------------------------------------------------

create or replace function private.notify_on_like() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  pile_id uuid;
  photo_owner uuid;
begin
  if tg_op = 'DELETE' then
    delete from notifications
     where kind = 'photo_like' and photo_id = old.photo_id and actor_id = old.user_id;
    return null;
  end if;
  select p.collection_id, coalesce(p.added_by, c.owner_id)
    into pile_id, photo_owner
    from photos p join collections c on c.id = p.collection_id
   where p.id = new.photo_id;
  if photo_owner is not null and photo_owner <> new.user_id
     and not private.blocked_between(photo_owner, new.user_id) then
    delete from notifications
     where kind = 'photo_like' and recipient_id = photo_owner
       and actor_id = new.user_id and photo_id = new.photo_id;
    insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id)
    values (photo_owner, new.user_id, 'photo_like', pile_id, new.photo_id);
  end if;
  return null;
end $$;
revoke execute on function private.notify_on_like() from public, anon, authenticated;
create trigger photo_likes_notify after insert or delete on photo_likes
  for each row execute function private.notify_on_like();

create or replace function private.notify_on_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  pile_id uuid;
  photo_owner uuid;
  batch_owner uuid;
  mentioned uuid;
begin
  select p.collection_id, coalesce(p.added_by, c.owner_id), c.owner_id
    into pile_id, photo_owner, batch_owner
    from photos p join collections c on c.id = p.collection_id
   where p.id = new.photo_id;
  if pile_id is null then
    return null;
  end if;

  -- @handle mentions in the comment body. A sentence-ending period is stripped unless an exact
  -- handle ending with a dot exists.
  for mentioned in
    select distinct pr.id
      from regexp_matches(lower(new.body), '(?:^|[^a-z0-9_.])@([a-z0-9_.]{3,25})', 'g') as m
      join profiles pr on pr.handle = m[1]
        or (not exists (select 1 from profiles exact where exact.handle = m[1])
            and pr.handle = rtrim(m[1], '.'))
     where pr.id <> new.author_id
       and not private.blocked_between(pr.id, new.author_id)
       and not private.blocked_between(pr.id, batch_owner)
  loop
    insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id, comment_id, body)
    values (mentioned, new.author_id, 'comment_mention', pile_id, new.photo_id, new.id, new.body);
  end loop;

  if photo_owner <> new.author_id
     and not private.blocked_between(photo_owner, new.author_id)
     and not exists (select 1 from notifications where comment_id = new.id and recipient_id = photo_owner) then
    insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id, comment_id, body)
    values (photo_owner, new.author_id, 'photo_comment', pile_id, new.photo_id, new.id, new.body);
  end if;

  if batch_owner <> photo_owner and batch_owner <> new.author_id
     and not private.blocked_between(batch_owner, new.author_id)
     and not exists (select 1 from notifications where comment_id = new.id and recipient_id = batch_owner) then
    insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id, comment_id, body)
    values (batch_owner, new.author_id, 'photo_comment', pile_id, new.photo_id, new.id, new.body);
  end if;

  return null;
end $$;
revoke execute on function private.notify_on_comment() from public, anon, authenticated;
create trigger photo_comments_notify after insert on photo_comments
  for each row execute function private.notify_on_comment();

create or replace function private.notify_on_tag() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  pile_id uuid;
begin
  if tg_op = 'DELETE' then
    delete from notifications
     where kind = 'photo_tag' and recipient_id = old.user_id and photo_id = old.photo_id;
    return null;
  end if;
  select collection_id into pile_id from photos where id = new.photo_id;
  if pile_id is not null and new.user_id <> new.tagged_by
     and not private.blocked_between(new.user_id, new.tagged_by) then
    delete from notifications
     where kind = 'photo_tag' and recipient_id = new.user_id and photo_id = new.photo_id;
    insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id)
    values (new.user_id, new.tagged_by, 'photo_tag', pile_id, new.photo_id);
  end if;
  return null;
end $$;
revoke execute on function private.notify_on_tag() from public, anon, authenticated;
create trigger photo_tags_notify after insert or delete on photo_tags
  for each row execute function private.notify_on_tag();

create or replace function private.notify_on_follow() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    delete from notifications
     where kind = 'follow' and recipient_id = old.followee_id and actor_id = old.follower_id;
    return null;
  end if;
  if new.followee_id <> new.follower_id
     and not private.blocked_between(new.followee_id, new.follower_id) then
    delete from notifications
     where kind = 'follow' and recipient_id = new.followee_id and actor_id = new.follower_id;
    insert into notifications (recipient_id, actor_id, kind)
    values (new.followee_id, new.follower_id, 'follow');
  end if;
  return null;
end $$;
revoke execute on function private.notify_on_follow() from public, anon, authenticated;
create trigger follows_notify after insert or delete on follows
  for each row execute function private.notify_on_follow();

-- Sharing replaces collection_members rows, so an existing share notification is kept as it was
-- unless the person was newly allowed to add photos.
create or replace function private.notify_on_share() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  batch_owner uuid;
  existing_id uuid;
  existing_body text;
  next_body text := case when new.can_add then 'can_add' else null end;
begin
  select owner_id into batch_owner from collections where id = new.collection_id;
  if batch_owner is null or new.user_id = batch_owner
     or private.blocked_between(new.user_id, batch_owner) then
    return null;
  end if;
  select id, body into existing_id, existing_body
    from notifications
   where kind = 'batch_shared'
     and recipient_id = new.user_id
     and collection_id = new.collection_id
   limit 1;
  if existing_id is not null then
    if new.can_add and existing_body is distinct from 'can_add' then
      update notifications
         set body = 'can_add', read_at = null, created_at = now()
       where id = existing_id;
    end if;
  else
    insert into notifications (recipient_id, actor_id, kind, collection_id, body)
    values (new.user_id, batch_owner, 'batch_shared', new.collection_id, next_body);
  end if;
  return null;
end $$;
revoke execute on function private.notify_on_share() from public, anon, authenticated;
create trigger collection_members_notify after insert on collection_members
  for each row execute function private.notify_on_share();

create or replace function private.notify_on_photo_added() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  batch_owner uuid;
  recent_id uuid;
  recent_count int;
begin
  if new.added_by is null then
    return null;
  end if;
  select owner_id into batch_owner from collections where id = new.collection_id;
  if batch_owner is null or batch_owner = new.added_by
     or private.blocked_between(batch_owner, new.added_by) then
    return null;
  end if;
  select id, coalesce(nullif(body, ''), '1')::int
    into recent_id, recent_count
    from notifications
   where kind = 'photo_added'
     and recipient_id = batch_owner
     and actor_id = new.added_by
     and collection_id = new.collection_id
     and read_at is null
     and created_at > now() - interval '15 minutes'
   order by created_at desc
   limit 1;
  if recent_id is not null then
    update notifications
       set body = (recent_count + 1)::text, photo_id = new.id, created_at = now()
     where id = recent_id;
  else
    insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id, body)
    values (batch_owner, new.added_by, 'photo_added', new.collection_id, new.id, '1');
  end if;
  return null;
end $$;
revoke execute on function private.notify_on_photo_added() from public, anon, authenticated;
create trigger photos_notify_added after insert on photos
  for each row execute function private.notify_on_photo_added();

-- Backfill existing likes and comments so upgrading accounts keep their recent activity.
insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id, created_at)
select coalesce(p.added_by, c.owner_id), l.user_id, 'photo_like', p.collection_id, l.photo_id, l.created_at
  from photo_likes l
  join photos p on p.id = l.photo_id
  join collections c on c.id = p.collection_id
 where coalesce(p.added_by, c.owner_id) <> l.user_id
   and not private.blocked_between(coalesce(p.added_by, c.owner_id), l.user_id);

insert into notifications (recipient_id, actor_id, kind, collection_id, photo_id, comment_id, body, created_at)
select coalesce(p.added_by, c.owner_id), pc.author_id, 'photo_comment', p.collection_id, pc.photo_id, pc.id, pc.body, pc.created_at
  from photo_comments pc
  join photos p on p.id = pc.photo_id
  join collections c on c.id = p.collection_id
 where coalesce(p.added_by, c.owner_id) <> pc.author_id
   and not private.blocked_between(coalesce(p.added_by, c.owner_id), pc.author_id);

-- Device push tokens ---------------------------------------------------------------------------

create table device_tokens (
  token text primary key check (char_length(token) between 32 and 512),
  user_id uuid not null default auth.uid() references profiles on delete cascade,
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on device_tokens (user_id);

alter table device_tokens enable row level security;
create policy "see own device tokens" on device_tokens for select to authenticated
  using (user_id = (select auth.uid()));
create policy "register own device token" on device_tokens for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "refresh own device token" on device_tokens for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "remove own device token" on device_tokens for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on device_tokens from anon, authenticated;
grant select, insert, update, delete on device_tokens to authenticated;

-- Blocking also removes tags and notifications between the two people --------------------------

create or replace function private.cut_ties_on_block() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from follows
   where (follower_id = new.blocker_id and followee_id = new.blocked_id)
      or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  delete from collection_members m using collections c
   where c.id = m.collection_id
     and ((c.owner_id = new.blocker_id and m.user_id = new.blocked_id)
       or (c.owner_id = new.blocked_id and m.user_id = new.blocker_id));
  delete from photo_tags pt using photos p, collections c
   where p.id = pt.photo_id and c.id = p.collection_id
     and ((pt.user_id = new.blocker_id and (pt.tagged_by = new.blocked_id or c.owner_id = new.blocked_id or p.added_by = new.blocked_id))
       or (pt.user_id = new.blocked_id and (pt.tagged_by = new.blocker_id or c.owner_id = new.blocker_id or p.added_by = new.blocker_id)));
  delete from notifications
   where (recipient_id = new.blocker_id and actor_id = new.blocked_id)
      or (recipient_id = new.blocked_id and actor_id = new.blocker_id);
  return null;
end $$;
revoke execute on function private.cut_ties_on_block() from public, anon, authenticated;
