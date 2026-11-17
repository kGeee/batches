-- Public batch links open without signing in --------------------------------------------------
-- A link to a batch the owner made Public (batches.space/b/<id>) now shows the batch and its
-- photos to someone who isn't signed in. Only 'public' batches: 'people' and 'followers' links
-- still ask the visitor to sign in, so nothing an owner limited becomes visible.
--
-- Signed-out visitors (the anon role) get read-only access to exactly what the batch page draws:
-- the batch row, its photos, the shared copies of those photos, and the profiles of its owner and
-- of whoever added photos to it. Likes, comments, tags, follows and everything else stay closed.
-- Blocks don't apply: there's no one signed in to be blocked.

grant select on collections, photos, profiles to anon;

create policy "anyone views public batches" on collections for select to anon
  using (visibility = 'public');

create policy "anyone views photos of public batches" on photos for select to anon
  using (exists (select 1 from collections c where c.id = collection_id and c.visibility = 'public'));

-- Just the people a public batch shows by name, not the whole profile directory.
create policy "anyone views people on public batches" on profiles for select to anon
  using (exists (select 1 from collections c where c.owner_id = profiles.id and c.visibility = 'public')
      or exists (select 1 from photos p join collections c on c.id = p.collection_id
                 where p.added_by = profiles.id and c.visibility = 'public'));

-- Shared copies are signed per path; anon may sign copies of photos in public batches.
create policy "anyone views shared copies of public batches" on storage.objects for select to anon
  using (bucket_id = 'media' and exists (
           select 1 from public.photos p join public.collections c on c.id = p.collection_id
            where p.id::text = (storage.foldername(name))[2]
              and p.share_path is not null
              and name like p.share_path || '/%'
              and c.visibility = 'public'));
