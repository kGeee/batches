-- Deleting an account failed when an open report pointed at that person, or at a batch, photo
-- or comment that disappeared with them. Those foreign keys are on delete set null, and the
-- table check required one of them to stay set, so clearing the last one was rejected:
-- "new row for relation reports violates check constraint reports_check".
-- context already keeps who and what was reported, which is what review needs after the
-- account is gone. Naming a person, batch, photo or comment is checked only when the report
-- is created.

alter table reports drop constraint reports_check;

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
  if new.reported_user_id is null and new.collection_id is null
     and new.photo_id is null and new.comment_id is null then
    raise exception 'a report has to name a person, a batch, a photo or a comment'
      using errcode = '23514';
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
