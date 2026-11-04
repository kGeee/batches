-- Shared copies (interim) -----------------------------------------------------------------------
-- Until the R2 setup in docs/storage-plan.md and supabase/storage.sql is live, shared copies go to
-- a private Supabase Storage bucket. Paths are {owner}/{photo}/{rev}/{s|m|l}.heic. Only owners
-- write their own folder; viewers can read a photo's copies when they can see its pile, and get
-- them as signed links. HEIC only, 5 MB at most: RAW files never go here.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', false, 5242880, array['image/heic'])
on conflict (id) do nothing;

create policy "upload own shared copies" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "delete own shared copies" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "view shared copies of allowed piles" on storage.objects for select to authenticated
  using (bucket_id = 'media' and (
         (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (select 1 from public.photos p join public.collections c on c.id = p.collection_id
                 where p.id::text = (storage.foldername(name))[2]
                   and p.share_path is not null
                   and name like p.share_path || '/%'
                   and public.can_view_collection(c))));
