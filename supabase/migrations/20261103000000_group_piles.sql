-- Group piles: the owner can let some of the people a pile is shared with add their own photos.
--
-- collection_members.can_add marks those people. Each photo records who added it in
-- photos.added_by (null means the pile's owner, which keeps every existing row as it was).
-- A contributor's shared copies live in their own folder of the media bucket, so a photo's
-- share_path always starts with whoever added it.
--
-- Who may do what:
--   owner        adds, reorders and removes any photo; title, cover, frame and sharing stay theirs
--   contributor  adds photos as themselves, edits and removes only the ones they added
--   viewer       unchanged

alter table collection_members add column can_add boolean not null default false;

alter table photos add column added_by uuid references profiles on delete set null;
create index photos_added_by_idx on photos (added_by);

-- Owners change who can add, as they already change who a pile is shared with.
create policy "owners change shares" on collection_members for update to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())))
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid())));

-- True when the signed-in person may add photos to the pile: they own it, or it's shared with
-- them with can_add. Like can_view_collection, only for policies.
create or replace function private.can_add_to_collection(pile uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from collections c
    where c.id = pile
      and (c.owner_id = auth.uid()
           or exists (select 1 from collection_members m
                      where m.collection_id = c.id and m.user_id = auth.uid() and m.can_add)));
$$;
revoke execute on function private.can_add_to_collection(uuid) from public, anon;
grant execute on function private.can_add_to_collection(uuid) to authenticated;

-- Who added a photo never changes, and only they can repoint its shared copies or change its
-- edit. The owner can still reorder, caption and remove anyone's photo.
create or replace function private.keep_photo_authorship() returns trigger
language plpgsql set search_path = public as $$
declare
  adder uuid := coalesce(old.added_by, (select owner_id from collections where id = old.collection_id));
begin
  new.added_by := old.added_by;
  new.collection_id := old.collection_id;
  if auth.uid() is distinct from adder then
    new.share_path := old.share_path;
    new.edit := old.edit;
  end if;
  return new;
end $$;
revoke execute on function private.keep_photo_authorship() from public, anon, authenticated;
create trigger photos_keep_authorship before update on photos
  for each row execute function private.keep_photo_authorship();

-- Adding: the owner adds as themselves (added_by null or their own id); a contributor must
-- name themselves. Either way share_path sits under the adder's own folder and this photo's id.
drop policy "owners add photos" on photos;
create policy "owners and contributors add photos" on photos for insert to authenticated
  with check (
    private.can_add_to_collection(collection_id)
    and (added_by = (select auth.uid())
         or (added_by is null and exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))))
    and (share_path is null
         or (split_part(share_path, '/', 1) = (select auth.uid())::text and split_part(share_path, '/', 2) = id::text)));

-- Editing: the owner, any photo in their pile; a contributor, their own while they can still add.
-- The trigger above keeps authorship and other people's copies as they were.
drop policy "owners edit photos" on photos;
create policy "owners and adders edit photos" on photos for update to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
         or (added_by = (select auth.uid()) and private.can_add_to_collection(collection_id)))
  with check (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
              or (added_by = (select auth.uid()) and private.can_add_to_collection(collection_id)));

-- Removing: the owner, any photo; a contributor, their own (even after losing can_add).
drop policy "owners delete photos" on photos;
create policy "owners and adders remove photos" on photos for delete to authenticated
  using (exists (select 1 from collections c where c.id = collection_id and c.owner_id = (select auth.uid()))
         or added_by = (select auth.uid()));

-- When the owner removes a contributor's photo, its copies in the contributor's folder go too.
create policy "pile owners delete copies of their piles" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and exists (
           select 1 from public.photos p join public.collections c on c.id = p.collection_id
           where p.id::text = (storage.foldername(name))[2]
             and p.share_path is not null
             and name like p.share_path || '/%'
             and c.owner_id = (select auth.uid())));
