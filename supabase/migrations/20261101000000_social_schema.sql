-- Strewn's social side: accounts, profiles, follows, piles and who can see them.
--
-- Who can see a pile is decided here, by row level security, never by the app:
--   private    only the owner
--   people     the owner and the people it's shared with (collection_members)
--   followers  the owner, their followers, and anyone it's shared with
--   public     anyone signed in to Strewn
-- supabase/tests/database/visibility.test.sql checks these rules.

-- Profiles ------------------------------------------------------------------------------------

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  handle text unique not null check (handle ~ '^[a-z0-9_.]{3,24}$'),
  display_name text not null check (length(display_name) between 1 and 60),
  avatar_url text,
  follower_count int not null default 0,     -- kept by triggers, not writable by clients
  following_count int not null default 0,
  created_at timestamptz not null default now()
);

create table follows (
  follower_id uuid references profiles on delete cascade,
  followee_id uuid references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index follows_followee_idx on follows (followee_id);

-- Piles and photos ----------------------------------------------------------------------------

create type pile_visibility as enum ('private', 'people', 'followers', 'public');

create table collections (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles on delete cascade,
  title text not null,
  place text,
  shot_on timestamptz,
  cover_photo_id uuid,                       -- set after photos exist
  frame jsonb not null default '{"kind":"whiteBorder","borderWidth":14,"wall":"light","layout":"single"}',
  visibility pile_visibility not null default 'private',
  like_count int not null default 0,         -- kept by triggers
  comment_count int not null default 0,
  created_at timestamptz not null default now()
);
create index collections_owner_idx on collections (owner_id, shot_on desc);

-- People a pile is shared with directly. They can view it; only the owner adds photos.
create table collection_members (
  collection_id uuid references collections on delete cascade,
  user_id uuid references profiles on delete cascade,
  added_at timestamptz not null default now(),
  primary key (collection_id, user_id)
);
create index collection_members_user_idx on collection_members (user_id);

-- What other people need to show a photo. The files themselves stay on the owner's phone
-- (developed image, RAW, original); viewers get the shared copies under share_path.
create table photos (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references collections on delete cascade,
  pixel_width int not null check (pixel_width > 0),   -- stored so clients lay out full frame before loading
  pixel_height int not null check (pixel_height > 0),
  caption text,
  captured_at timestamptz,
  exif jsonb,
  sort_index int not null default 0,
  edit jsonb,                                -- non-destructive EditRecipe; null = unedited
  share_path text,                           -- {owner}/{photo}/{rev} in the media bucket; null until shared
  created_at timestamptz not null default now()
);
create index photos_collection_idx on photos (collection_id, sort_index);

alter table collections
  add constraint collections_cover_fk foreign key (cover_photo_id) references photos on delete set null;

create table likes (
  user_id uuid references profiles on delete cascade,
  collection_id uuid references collections on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, collection_id)
);

create table comments (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references collections on delete cascade,
  author_id uuid not null references profiles on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

-- Who can see a pile ----------------------------------------------------------------------------

create or replace function can_view_collection(c collections) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
       c.owner_id = auth.uid()
    or c.visibility = 'public'
    or (c.visibility = 'followers' and exists (
          select 1 from follows where follower_id = auth.uid() and followee_id = c.owner_id))
    or (c.visibility in ('people', 'followers') and exists (
          select 1 from collection_members m where m.collection_id = c.id and m.user_id = auth.uid())));
$$;

-- Counts ----------------------------------------------------------------------------------------

create or replace function track_follow_counts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update profiles set following_count = following_count + 1 where id = new.follower_id;
    update profiles set follower_count = follower_count + 1 where id = new.followee_id;
  else
    update profiles set following_count = greatest(0, following_count - 1) where id = old.follower_id;
    update profiles set follower_count = greatest(0, follower_count - 1) where id = old.followee_id;
  end if;
  return null;
end $$;
create trigger follows_counts after insert or delete on follows
  for each row execute function track_follow_counts();

create or replace function track_pile_counts() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  delta int := case when tg_op = 'INSERT' then 1 else -1 end;
  pile uuid := case when tg_op = 'INSERT' then new.collection_id else old.collection_id end;
begin
  if tg_table_name = 'likes' then
    update collections set like_count = greatest(0, like_count + delta) where id = pile;
  else
    update collections set comment_count = greatest(0, comment_count + delta) where id = pile;
  end if;
  return null;
end $$;
create trigger likes_counts after insert or delete on likes for each row execute function track_pile_counts();
create trigger comments_counts after insert or delete on comments for each row execute function track_pile_counts();

-- Row level security ------------------------------------------------------------------------------
-- Policies call auth.uid() through a subselect so it's evaluated once per query, not once per row.

alter table profiles enable row level security;
alter table follows enable row level security;
alter table collections enable row level security;
alter table collection_members enable row level security;
alter table photos enable row level security;
alter table likes enable row level security;
alter table comments enable row level security;

-- Profiles are visible to anyone signed in, so friends can find each other.
create policy "profiles are readable" on profiles for select to authenticated using (true);
create policy "create own profile" on profiles for insert to authenticated with check (id = (select auth.uid()));
create policy "edit own profile" on profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Follows are visible to anyone signed in (follower lists), and you only follow as yourself.
create policy "follows are readable" on follows for select to authenticated using (true);
create policy "follow as yourself" on follows for insert to authenticated with check (follower_id = (select auth.uid()));
create policy "unfollow as yourself" on follows for delete to authenticated using (follower_id = (select auth.uid()));

create policy "view allowed piles" on collections for select to authenticated using (can_view_collection(collections));
create policy "owners write piles" on collections for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

-- The owner sees and changes who a pile is shared with; each person sees their own shares.
create policy "see shares" on collection_members for select to authenticated
  using (user_id = (select auth.uid())
         or exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())));
create policy "owners share" on collection_members for insert to authenticated
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())));
create policy "owners unshare" on collection_members for delete to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())));

create policy "view photos of allowed piles" on photos for select to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and can_view_collection(c)));
-- share_path must sit under the owner's own folder and this photo's id.
create policy "owners write photos" on photos for all to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())))
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
              and (share_path is null
                   or (split_part(share_path, '/', 1) = (select auth.uid())::text and split_part(share_path, '/', 2) = id::text)));

create policy "read likes on allowed piles" on likes for select to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and can_view_collection(c)));
create policy "like as yourself" on likes for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from collections c where c.id = collection_id and can_view_collection(c)));
create policy "unlike as yourself" on likes for delete to authenticated using (user_id = (select auth.uid()));

create policy "read comments on allowed piles" on comments for select to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and can_view_collection(c)));
create policy "comment as yourself" on comments for insert to authenticated
  with check (author_id = (select auth.uid()) and exists (select 1 from collections c where c.id = collection_id and can_view_collection(c)));
create policy "delete own comments" on comments for delete to authenticated using (author_id = (select auth.uid()));

-- Grants. Signed-in clients get table access (row level security above narrows it); anon gets
-- nothing. Counts are only changed by the triggers above, so clients get column-level write access.
grant select, insert, update, delete on profiles, follows, collections, collection_members, photos, likes, comments
  to authenticated;
revoke insert, update on profiles, collections from anon, authenticated;
grant insert (id, handle, display_name, avatar_url) on profiles to authenticated;
grant update (handle, display_name, avatar_url) on profiles to authenticated;
grant insert (id, owner_id, title, place, shot_on, cover_photo_id, frame, visibility) on collections to authenticated;
grant update (id, owner_id, title, place, shot_on, cover_photo_id, frame, visibility) on collections to authenticated;
revoke all on profiles, follows, collections, collection_members, photos, likes, comments from anon;
revoke execute on function can_view_collection(collections) from public, anon;
grant execute on function can_view_collection(collections) to authenticated;
