-- Likes and comments on single photos, a short description for a batch, and a batch background.
--
-- Additive, so builds 7 and 8 keep working: they read collections with `*` and ignore columns they
-- don't know, their saves name their own columns, and they never touch the new tables. The
-- background is its own column rather than a new FrameStyle.wall value, because those builds fail
-- to decode a frame with a wall they don't know. The app also keeps frame.wall set to the nearest
-- of light, dark and desk, so older builds show something close.
--
-- The batch-level likes and comments tables from the first migration are left as they are. The
-- app never used them.

-- Description and background ----------------------------------------------------------------

alter table collections
  add column description text check (char_length(description) <= 280),
  -- One of the presets, or a custom colour as #rrggbb.
  add column background text check (background in ('light', 'dark', 'desk', 'kraft') or background ~ '^#[0-9a-f]{6}$');

-- collections has column-level grants; "owners write piles" still limits these to the owner.
grant insert (description, background), update (description, background) on collections to authenticated;

-- Who can see a photo -----------------------------------------------------------------------
-- The same as the photos select policy: its batch is visible to you, and whoever added it isn't
-- on the other side of a block. Security definer so policies on other tables can ask. Only for
-- policies.

create or replace function private.can_view_photo(photo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from photos p join collections c on c.id = p.collection_id
    where p.id = photo
      and private.can_view_collection(c)
      and (p.added_by is null or p.added_by = auth.uid() or not private.blocked_between(auth.uid(), p.added_by)));
$$;
revoke execute on function private.can_view_photo(uuid) from public, anon;
grant execute on function private.can_view_photo(uuid) to authenticated;

-- Likes ---------------------------------------------------------------------------------------

create table photo_likes (
  photo_id uuid references photos on delete cascade,
  user_id uuid default auth.uid() references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (photo_id, user_id)
);
create index photo_likes_user_idx on photo_likes (user_id);

alter table photo_likes enable row level security;
-- You see likes on photos you can see, except from people on the other side of a block.
create policy "read likes on visible photos" on photo_likes for select to authenticated
  using (private.can_view_photo(photo_id)
         and (user_id = (select auth.uid()) or not private.blocked_between((select auth.uid()), user_id)));
create policy "like as yourself" on photo_likes for insert to authenticated
  with check (user_id = (select auth.uid()) and private.can_view_photo(photo_id));
create policy "unlike as yourself" on photo_likes for delete to authenticated
  using (user_id = (select auth.uid()));
-- Supabase grants every table to anon and authenticated by default, so start from nothing.
revoke all on photo_likes from anon, authenticated;
grant select, delete on photo_likes to authenticated;
grant insert (photo_id, user_id) on photo_likes to authenticated;

-- Comments ------------------------------------------------------------------------------------
-- Readable by whoever can see the photo, hidden between blocked people both ways, removable by
-- their author and by the batch's owner, and reportable. Comments can't be edited.

create table photo_comments (
  id uuid primary key default gen_random_uuid(),
  photo_id uuid not null references photos on delete cascade,
  author_id uuid not null default auth.uid() references profiles on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index photo_comments_photo_idx on photo_comments (photo_id, created_at);
create index photo_comments_author_idx on photo_comments (author_id);

alter table photo_comments enable row level security;
create policy "read comments on visible photos" on photo_comments for select to authenticated
  using (private.can_view_photo(photo_id)
         and (author_id = (select auth.uid()) or not private.blocked_between((select auth.uid()), author_id)));
create policy "comment as yourself" on photo_comments for insert to authenticated
  with check (author_id = (select auth.uid()) and private.can_view_photo(photo_id));
create policy "authors and batch owners remove comments" on photo_comments for delete to authenticated
  using (author_id = (select auth.uid())
         or exists (select 1 from photos p join collections c on c.id = p.collection_id
                    where p.id = photo_id and c.owner_id = (select auth.uid())));
-- Supabase grants every table to anon and authenticated by default, so start from nothing.
revoke all on photo_comments from anon, authenticated;
grant select, delete on photo_comments to authenticated;
grant insert (id, photo_id, author_id, body) on photo_comments to authenticated;

-- Reporting a comment -------------------------------------------------------------------------
-- A report can name a comment. The trigger fills in its photo and author, so the existing check
-- (someone, a batch or a photo) still holds, and keeps the comment's words in case it's deleted.

alter table reports add column comment_id uuid references photo_comments on delete set null;
create index reports_comment_idx on reports (comment_id);
grant insert (comment_id) on reports to authenticated;

create or replace function private.fill_report_context() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.comment_id is not null then
    select coalesce(new.photo_id, pc.photo_id), coalesce(new.reported_user_id, pc.author_id)
      into new.photo_id, new.reported_user_id
      from photo_comments pc where pc.id = new.comment_id;
  end if;
  if new.photo_id is not null then
    select coalesce(new.collection_id, p.collection_id), coalesce(new.reported_user_id, p.added_by, c.owner_id)
      into new.collection_id, new.reported_user_id
      from photos p join collections c on c.id = p.collection_id where p.id = new.photo_id;
  end if;
  if new.collection_id is not null and new.reported_user_id is null then
    select owner_id into new.reported_user_id from collections where id = new.collection_id;
  end if;
  new.context := jsonb_strip_nulls(jsonb_build_object(
    'reporter_handle', (select handle from profiles where id = new.reporter_id),
    'reported_handle', (select handle from profiles where id = new.reported_user_id),
    'batch_title', (select title from collections where id = new.collection_id),
    'photo_share_path', (select share_path from photos where id = new.photo_id),
    'comment_body', (select body from photo_comments where id = new.comment_id)));
  return new;
end $$;
revoke execute on function private.fill_report_context() from public, anon, authenticated;

-- Deleting an account removes your likes and comments: both cascade from your profile, and from
-- your photos when they go.
