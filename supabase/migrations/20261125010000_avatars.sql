-- Profile pictures ------------------------------------------------------------------------------
-- A public bucket, since a face shows wherever the person does (feeds, comments, link previews)
-- and signing every avatar would cost a request per face. Paths are {user}/{random}.jpg; each
-- person writes only their own folder. JPEG only, 1 MB at most (the app sends 512 px squares).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

create policy "upload own avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "replace own avatar" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "delete own avatar" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
-- Listing your own folder, so the app can clear out pictures you've replaced.
create policy "list own avatars" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
