-- Follow-ups from the database advisors after the first two migrations.

-- can_view_collection is only for policies. In an unexposed schema the Data API can't offer it as
-- an RPC; the policies that use it keep pointing at it after the move.
create schema if not exists private;
grant usage on schema private to authenticated;
alter function public.can_view_collection(collections) set schema private;

-- Trigger functions run as their trigger, never called directly.
revoke execute on function track_follow_counts(), track_pile_counts() from public, anon, authenticated;

-- "for all" owner policies also applied to select, so every read checked two policies. Owners
-- already pass "view allowed piles" / "view photos of allowed piles", so split them by action.
drop policy "owners write piles" on collections;
create policy "owners create piles" on collections for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy "owners edit piles" on collections for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "owners delete piles" on collections for delete to authenticated
  using (owner_id = (select auth.uid()));

drop policy "owners write photos" on photos;
-- share_path must sit under the owner's own folder and this photo's id.
create policy "owners add photos" on photos for insert to authenticated
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
              and (share_path is null
                   or (split_part(share_path, '/', 1) = (select auth.uid())::text and split_part(share_path, '/', 2) = id::text)));
create policy "owners edit photos" on photos for update to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())))
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
              and (share_path is null
                   or (split_part(share_path, '/', 1) = (select auth.uid())::text and split_part(share_path, '/', 2) = id::text)));
create policy "owners delete photos" on photos for delete to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())));

-- Foreign keys without an index (deletes and cascades scan otherwise).
create index collections_cover_idx on collections (cover_photo_id);
create index likes_collection_idx on likes (collection_id);
create index comments_collection_idx on comments (collection_id, created_at);
create index comments_author_idx on comments (author_id);
