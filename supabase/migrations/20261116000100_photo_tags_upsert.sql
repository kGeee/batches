-- Clients save tags with an upsert (insert ... on conflict do update), and PostgREST's update half
-- sets every column it was sent, primary key included. Without update rights on photo_id and user_id
-- that upsert was denied, so no tag could be saved. Allow those columns, and keep a tag pinned to its
-- photo and person: an update may move the pin or take over the tag, never retarget it.

grant update (photo_id, user_id) on photo_tags to authenticated;

create or replace function private.photo_tags_keep_target() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.photo_id <> old.photo_id or new.user_id <> old.user_id then
    raise exception 'a photo tag cannot be moved to another photo or person'
      using errcode = '42501';
  end if;
  return new;
end $$;
revoke execute on function private.photo_tags_keep_target() from public, anon, authenticated;

create trigger photo_tags_keep_target before update on photo_tags
  for each row execute function private.photo_tags_keep_target();
