-- Photo tags, @handle mentions, notifications, block cleanup and device tokens, checked as each
-- person. Everything is rolled back at the end.
--
-- People: kevin (a), maya (b), theo (d, contributor), jules (c), stranger (e).
begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000aa'),
  ('00000000-0000-0000-0000-0000000000bb'),
  ('00000000-0000-0000-0000-0000000000cc'),
  ('00000000-0000-0000-0000-0000000000dd'),
  ('00000000-0000-0000-0000-0000000000ee');

create function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true)
$$;
create function pg_temp.try(q text) returns text language plpgsql as $$
declare n int;
begin
  execute q;
  get diagnostics n = row_count;
  return case when n = 0 then '0 rows' else 'ok' end;
exception when insufficient_privilege or check_violation then
  return 'refused';
end $$;
grant execute on function pg_temp.as_user(text), pg_temp.try(text) to authenticated;

set local role authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000aa', 'kevin_tn', 'Kevin');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000bb', 'maya.tn', 'Maya');
insert into follows (follower_id, followee_id) values ('00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000aa');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000cc');
insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000cc', 'jules_tn', 'Jules');
insert into follows (follower_id, followee_id) values ('00000000-0000-0000-0000-0000000000cc', '00000000-0000-0000-0000-0000000000aa');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000dd');
insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000dd', 'theo_tn', 'Theo');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000ee');
insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000ee', 'stranger_tn', 'Stranger');

-- Follow notifications -------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000aa' and kind = 'follow'), '2', 'kevin receives follow notifications from maya and jules');

-- Private batch tags do not leak before sharing ------------------------------------------------
insert into collections (id, owner_id, title, frame, visibility)
values ('11000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'Secret Coast', '{}', 'private');
insert into photos (id, collection_id, pixel_width, pixel_height)
values ('22000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', 3024, 4032);

select is(pg_temp.try($$insert into photo_tags (photo_id, user_id, x, y) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000bb', 0.42, 0.31)$$), 'ok', 'owner tags maya at a pin position');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id, x, y) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000cc', 1.4, 0.5)$$), 'refused', 'coordinates outside 0..1 are refused');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id, x) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000cc', 0.5)$$), 'refused', 'half-set pin coordinates are refused');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000cc')$$), 'ok', 'owner tags jules without pin coordinates');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
select is((select count(*)::text from photo_tags where photo_id = '22000000-0000-0000-0000-000000000001'), '0', 'maya cannot read tags while the batch is private');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000bb' and kind = 'photo_tag'), '0', 'maya does not see a tag notification while the batch is private');

-- Sharing reveals tags and share notifications -------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
update collections set visibility = 'followers' where id = '11000000-0000-0000-0000-000000000001';
insert into collection_members (collection_id, user_id, can_add)
values ('11000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000dd', false);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
select is((select count(*)::text from photo_tags where photo_id = '22000000-0000-0000-0000-000000000001'), '2', 'once shared with followers, maya sees the tags');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000bb' and kind = 'photo_tag'), '1', 'and maya now sees her photo_tag notification');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000dd');
select is((select coalesce(body, 'view') from notifications where recipient_id = '00000000-0000-0000-0000-0000000000dd' and kind = 'batch_shared' and collection_id = '11000000-0000-0000-0000-000000000001'), 'view', 'theo gets a batch_shared notification');
update notifications set read_at = now() where recipient_id = '00000000-0000-0000-0000-0000000000dd' and kind = 'batch_shared';

-- Re-saving collection_members preserves read share notification unless promoted to can_add ----
select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
delete from collection_members where collection_id = '11000000-0000-0000-0000-000000000001';
insert into collection_members (collection_id, user_id, can_add)
values ('11000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000dd', false);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000dd');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000dd' and kind = 'batch_shared' and read_at is null), '0', 're-saving unchanged member list does not re-unread theo''s notification');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
delete from collection_members where collection_id = '11000000-0000-0000-0000-000000000001';
insert into collection_members (collection_id, user_id, can_add)
values ('11000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000dd', true);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000dd');
select is((select body from notifications where recipient_id = '00000000-0000-0000-0000-0000000000dd' and kind = 'batch_shared' and read_at is null), 'can_add', 'promoting theo to contributor marks batch_shared unread with can_add');

-- Contributor permissions & photo_added coalescing --------------------------------------------
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000dd')$$), 'refused', 'contributor cannot tag people on the owner''s photo');

insert into photos (id, collection_id, pixel_width, pixel_height, added_by, share_path) values
  ('22000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000001', 4032, 3024, '00000000-0000-0000-0000-0000000000dd', '00000000-0000-0000-0000-0000000000dd/22000000-0000-0000-0000-000000000002/rev1'),
  ('22000000-0000-0000-0000-000000000003', '11000000-0000-0000-0000-000000000001', 4032, 3024, '00000000-0000-0000-0000-0000000000dd', '00000000-0000-0000-0000-0000000000dd/22000000-0000-0000-0000-000000000003/rev1');

select is(pg_temp.try($$insert into photo_tags (photo_id, user_id, x, y) values ('22000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000bb', 0.25, 0.6)$$), 'ok', 'contributor can tag people on a photo they added');
select is(pg_temp.try($$update photo_tags set x = 0.3, y = 0.65 where photo_id = '22000000-0000-0000-0000-000000000002' and user_id = '00000000-0000-0000-0000-0000000000bb'$$), 'ok', 'contributor can move a tag pin on their photo');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
select is((select body from notifications where recipient_id = '00000000-0000-0000-0000-0000000000aa' and kind = 'photo_added' and collection_id = '11000000-0000-0000-0000-000000000001'), '2', 'two contributed photos coalesce into one photo_added notification with count 2');

-- Stranger & follower tag restrictions, and self-untagging -------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000ee');
select is((select count(*)::text from photo_tags where photo_id = '22000000-0000-0000-0000-000000000001'), '0', 'stranger sees no tags');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000ee')$$), 'refused', 'stranger cannot tag anyone');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000dd')$$), 'refused', 'viewer cannot tag people on someone else''s photo');
select is(pg_temp.try($$delete from photo_tags where photo_id = '22000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-0000000000cc'$$), '0 rows', 'viewer cannot remove someone else''s tag');
select is(pg_temp.try($$delete from photo_tags where photo_id = '22000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-0000000000bb'$$), 'ok', 'tagged person can untag themselves');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000bb' and kind = 'photo_tag' and photo_id = '22000000-0000-0000-0000-000000000001'), '0', 'untagging clears the photo_tag notification for that photo');

-- Likes, comments, @handle mentions and cascade cleanup ----------------------------------------
insert into photo_likes (photo_id) values ('22000000-0000-0000-0000-000000000001');
insert into photo_comments (id, photo_id, body)
values ('33000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000002', 'Great shot @theo_tn and @jules_tn.');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000aa' and kind = 'photo_like' and photo_id = '22000000-0000-0000-0000-000000000001'), '1', 'kevin receives a photo_like notification');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000aa' and kind = 'photo_comment' and comment_id = '33000000-0000-0000-0000-000000000001'), '1', 'batch owner receives photo_comment on a contributed photo');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000dd');
select is((select string_agg(kind, ',' order by kind) from notifications where recipient_id = '00000000-0000-0000-0000-0000000000dd' and comment_id = '33000000-0000-0000-0000-000000000001'), 'comment_mention', 'mentioned photo author gets one comment_mention, not a duplicate photo_comment');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000cc' and kind = 'comment_mention' and comment_id = '33000000-0000-0000-0000-000000000001'), '1', 'jules receives comment_mention even with a trailing sentence period');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
delete from photo_likes where photo_id = '22000000-0000-0000-0000-000000000001';
delete from photo_comments where id = '33000000-0000-0000-0000-000000000001';

select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000aa' and kind = 'photo_like' and photo_id = '22000000-0000-0000-0000-000000000001'), '0', 'unliking removes the photo_like notification');
select is((select count(*)::text from notifications where comment_id = '33000000-0000-0000-0000-000000000001'), '0', 'deleting a comment removes its comment and mention notifications');

-- Notification write protections ---------------------------------------------------------------
select is(pg_temp.try($$insert into notifications (recipient_id, actor_id, kind) values ('00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000aa', 'follow')$$), 'refused', 'clients cannot forge notifications directly');
select is(pg_temp.try($$update notifications set kind = 'photo_like' where recipient_id = '00000000-0000-0000-0000-0000000000aa'$$), 'refused', 'clients cannot alter notification kind');
select is(pg_temp.try($$update notifications set read_at = now() where recipient_id = '00000000-0000-0000-0000-0000000000bb'$$), '0 rows', 'clients cannot mark someone else''s notifications read');
select is(pg_temp.try($$update notifications set read_at = now() where recipient_id = '00000000-0000-0000-0000-0000000000aa' and kind = 'follow'$$), 'ok', 'recipient marks their own notifications read');

-- Device push tokens ---------------------------------------------------------------------------
select is(pg_temp.try($$insert into device_tokens (token, environment) values (repeat('a1', 32), 'production')$$), 'ok', 'user registers their own APNs token');
select is(pg_temp.try($$insert into device_tokens (token, user_id) values (repeat('b2', 32), '00000000-0000-0000-0000-0000000000bb')$$), 'refused', 'user cannot register a token for someone else');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
select is((select count(*)::text from device_tokens), '0', 'another user cannot see kevin''s device tokens');

-- Blocking cuts tags and notifications both ways -----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000aa');
insert into blocks (blocker_id, blocked_id)
values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000cc');

select is((select count(*)::text from photo_tags where photo_id = '22000000-0000-0000-0000-000000000001' and user_id = '00000000-0000-0000-0000-0000000000cc'), '0', 'blocking removes tags between the two people');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000aa' and actor_id = '00000000-0000-0000-0000-0000000000cc'), '0', 'blocking removes notifications between the two people');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id) values ('22000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000cc')$$), 'refused', 'cannot tag across a block');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000dd');
select is(pg_temp.try($$insert into photo_tags (photo_id, user_id) values ('22000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000cc')$$), 'refused', 'contributor cannot tag someone the batch owner has blocked');

-- Account deletion cascades tags, notifications and device tokens ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000bb');
select lives_ok($$select public.delete_account()$$, 'maya deletes her account cleanly');

reset role;
select is((select count(*)::text from photo_tags where user_id = '00000000-0000-0000-0000-0000000000bb'), '0', 'deleted user''s tags are removed');
select is((select count(*)::text from notifications where recipient_id = '00000000-0000-0000-0000-0000000000bb' or actor_id = '00000000-0000-0000-0000-0000000000bb'), '0', 'deleted user''s notifications are removed');

select * from finish();
rollback;
