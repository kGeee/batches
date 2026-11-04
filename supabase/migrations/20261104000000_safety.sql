-- Safety: blocking people, reporting batches, photos and people, and deleting your own account.
-- The App Store asks for all three in apps where people share photos with each other
-- (guidelines 1.2 and 5.1.1(v)), and Beta App Review can hold an external build without them.
--
-- Blocking works both ways and quietly: once either person blocks the other, neither sees the
-- other's batches or the photos they added to anyone's batch, follows between them are removed
-- and can't be made again, and batches shared between them stop being shared. Only the blocker
-- can see or undo the block.

-- Blocks --------------------------------------------------------------------------------------

create table blocks (
  blocker_id uuid references profiles on delete cascade,
  blocked_id uuid references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on blocks (blocked_id);

alter table blocks enable row level security;
create policy "see own blocks" on blocks for select to authenticated using (blocker_id = (select auth.uid()));
create policy "block as yourself" on blocks for insert to authenticated with check (blocker_id = (select auth.uid()));
create policy "unblock as yourself" on blocks for delete to authenticated using (blocker_id = (select auth.uid()));
grant select, insert, delete on blocks to authenticated;
revoke all on blocks from anon;

-- True when either person has blocked the other. Security definer so it sees the other side's
-- blocks, which row level security hides from you. Only for policies.
create or replace function private.blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks
                 where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;
revoke execute on function private.blocked_between(uuid, uuid) from public, anon;
grant execute on function private.blocked_between(uuid, uuid) to authenticated;

-- A new block removes what connects the two people.
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
  return null;
end $$;
revoke execute on function private.cut_ties_on_block() from public, anon, authenticated;
create trigger blocks_cut_ties after insert on blocks
  for each row execute function private.cut_ties_on_block();

-- Visibility, as in the first migration, plus: never a batch of someone on the other side of a block.
create or replace function private.can_view_collection(c collections) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
       c.owner_id = auth.uid()
    or (not private.blocked_between(auth.uid(), c.owner_id) and (
            c.visibility = 'public'
         or (c.visibility = 'followers' and exists (
               select 1 from follows where follower_id = auth.uid() and followee_id = c.owner_id))
         or (c.visibility in ('people', 'followers') and exists (
               select 1 from collection_members m where m.collection_id = c.id and m.user_id = auth.uid())))));
$$;

-- Photos someone on the other side of a block added to a batch you can see are hidden too.
drop policy "view photos of allowed piles" on photos;
create policy "view photos of allowed piles" on photos for select to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and private.can_view_collection(c))
         and (added_by is null or added_by = (select auth.uid()) or not private.blocked_between((select auth.uid()), added_by)));

-- No following or sharing across a block.
drop policy "follow as yourself" on follows;
create policy "follow as yourself" on follows for insert to authenticated
  with check (follower_id = (select auth.uid()) and not private.blocked_between(follower_id, followee_id));

drop policy "owners share" on collection_members;
create policy "owners share" on collection_members for insert to authenticated
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
              and not private.blocked_between((select auth.uid()), user_id));

-- Reports -------------------------------------------------------------------------------------
-- Anyone signed in can report a person, a batch or a photo. Nobody can read reports through the
-- app; you review them in the dashboard (Table Editor → reports) and act within a day, as Apple
-- expects. context keeps what was reported even after it's deleted.

create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid default auth.uid() references profiles on delete set null,
  reported_user_id uuid references profiles on delete set null,
  collection_id uuid references collections on delete set null,
  photo_id uuid references photos on delete set null,
  reason text not null check (reason in ('spam', 'nudity', 'harassment', 'violence', 'copyright', 'other')),
  details text check (length(details) <= 1000),
  context jsonb,
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  check (reported_user_id is not null or collection_id is not null or photo_id is not null)
);
create index reports_open_idx on reports (created_at) where status = 'open';
create index reports_reporter_idx on reports (reporter_id);
create index reports_user_idx on reports (reported_user_id);
create index reports_collection_idx on reports (collection_id);
create index reports_photo_idx on reports (photo_id);

alter table reports enable row level security;
create policy "report as yourself" on reports for insert to authenticated
  with check (reporter_id = (select auth.uid()));
revoke all on reports from anon, authenticated;
grant insert (reported_user_id, collection_id, photo_id, reason, details) on reports to authenticated;

-- Fills in who owns what was reported, the batch's title, and where the photo's copies are.
create or replace function private.fill_report_context() returns trigger
language plpgsql security definer set search_path = public as $$
begin
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
    'photo_share_path', (select share_path from photos where id = new.photo_id)));
  return new;
end $$;
revoke execute on function private.fill_report_context() from public, anon, authenticated;
create trigger reports_fill_context before insert on reports
  for each row execute function private.fill_report_context();

-- Deleting an account -----------------------------------------------------------------------
-- The app removes your shared copies from storage first (Storage keeps files out of SQL's reach),
-- then calls this. Deleting the auth user cascades to your profile, batches, their photos,
-- shares, follows, likes, comments and blocks. Photos you added to friends' batches go first:
-- added_by would otherwise fall back to null, which means the batch's owner.

create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  delete from photos where added_by = me;
  delete from auth.users where id = me;
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
