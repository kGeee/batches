-- Photo likes and comments, comment reports, batch description and background, checked as each
-- person. Run like visibility.test.sql; everything is rolled back.
--
-- People: kevin (a) owns a followers batch, maya (b) follows him and can see it, jules (c) follows
-- him too but has blocked maya, stranger (e) sees nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(34);
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a'),('00000000-0000-0000-0000-00000000000b'),('00000000-0000-0000-0000-00000000000c'),('00000000-0000-0000-0000-00000000000e');
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
-- What a statement did: 'ok', '0 rows' (filtered out by a policy) or 'refused' (blocked).
create function pg_temp.try(q text) returns text language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return case when n = 0 then '0 rows' else 'ok' end;
exception when insufficient_privilege or check_violation then return 'refused'; end $$;
grant execute on function pg_temp.as_user(text), pg_temp.try(text) to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000a','kevin','K');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000b','maya','M');
insert into follows (follower_id, followee_id) values ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000c','jules','J');
insert into follows (follower_id, followee_id) values ('00000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000e','stranger','X');

-- kevin's batch, the way builds 7 and 8 write it: no description or background
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into collections (id, owner_id, title, frame, visibility) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','Trip','{}','followers');
insert into photos (id, collection_id, pixel_width, pixel_height) values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',3,2);
select is((select coalesce(description, 'none') || ' ' || coalesce(background, 'none') from collections where id = '10000000-0000-0000-0000-000000000001'), 'none none', 'description and background start empty');
select is(pg_temp.try($$update collections set description = 'Two days on the coast.', background = 'kraft' where id = '10000000-0000-0000-0000-000000000001'$$), 'ok', 'owner sets a description and a preset background');
select is(pg_temp.try($$update collections set background = '#1a2b3c' where id = '10000000-0000-0000-0000-000000000001'$$), 'ok', 'owner sets a custom colour');
select is(pg_temp.try($$update collections set background = 'neon' where id = '10000000-0000-0000-0000-000000000001'$$), 'refused', 'an unknown background is refused');
select is(pg_temp.try($$update collections set background = '#ZZZZZZ' where id = '10000000-0000-0000-0000-000000000001'$$), 'refused', 'a malformed colour is refused');
select is(pg_temp.try($$update collections set description = repeat('x', 281) where id = '10000000-0000-0000-0000-000000000001'$$), 'refused', 'a description over 280 characters is refused');
select is(pg_temp.try($$update collections set title = 'Trip 2', frame = '{"wall":"light"}' where id = '10000000-0000-0000-0000-000000000001'$$), 'ok', 'older builds still save their own columns');
select is((select description || ' ' || background from collections where id = '10000000-0000-0000-0000-000000000001'), 'Two days on the coast. #1a2b3c', 'and leave description and background alone');

-- jules blocks maya
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
insert into blocks (blocker_id, blocked_id) values ('00000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-00000000000b');

-- maya, a follower, sees it, can't change it, likes and comments
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is((select description from collections where id = '10000000-0000-0000-0000-000000000001'), 'Two days on the coast.', 'a follower sees the description');
select is(pg_temp.try($$update collections set description = 'mine' where id = '10000000-0000-0000-0000-000000000001'$$), '0 rows', 'a follower changes the description');
select is(pg_temp.try($$insert into photo_likes (photo_id) values ('20000000-0000-0000-0000-000000000001')$$), 'ok', 'a follower likes a photo');
select is(pg_temp.try($$insert into photo_likes (photo_id, user_id) values ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a')$$), 'refused', 'a follower likes as someone else');
select is(pg_temp.try($$insert into photo_comments (id, photo_id, body) values ('30000000-0000-0000-0000-00000000000b','20000000-0000-0000-0000-000000000001','Lovely light')$$), 'ok', 'a follower comments');
select is(pg_temp.try($$insert into photo_comments (photo_id, author_id, body) values ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','fake')$$), 'refused', 'a follower comments as someone else');
select is(pg_temp.try($$insert into photo_comments (photo_id, body) values ('20000000-0000-0000-0000-000000000001','   ')$$), 'refused', 'a blank comment is refused');
select is(pg_temp.try($$insert into photo_comments (photo_id, body) values ('20000000-0000-0000-0000-000000000001', repeat('x', 501))$$), 'refused', 'a comment over 500 characters is refused');
select is(pg_temp.try($$update photo_comments set body = 'edited' where id = '30000000-0000-0000-0000-00000000000b'$$), 'refused', 'comments can''t be edited');

-- jules, also a follower, comments too; neither jules nor maya sees the other's
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select is(pg_temp.try($$insert into photo_comments (id, photo_id, body) values ('30000000-0000-0000-0000-00000000000c','20000000-0000-0000-0000-000000000001','Where is this?')$$), 'ok', 'another follower comments');
insert into photo_likes (photo_id) values ('20000000-0000-0000-0000-000000000001');
select is((select string_agg(body, '|' order by body) from photo_comments where photo_id = '20000000-0000-0000-0000-000000000001'), 'Where is this?', 'the blocker doesn''t see the blocked person''s comment');
select is((select count(*)::text from photo_likes where photo_id = '20000000-0000-0000-0000-000000000001'), '1', 'or their like');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is((select string_agg(body, '|' order by body) from photo_comments where photo_id = '20000000-0000-0000-0000-000000000001'), 'Lovely light', 'the blocked person doesn''t see the blocker''s comment');
select is(pg_temp.try($$delete from photo_comments where id = '30000000-0000-0000-0000-00000000000c'$$), '0 rows', 'a follower deletes someone else''s comment');

-- maya reports jules's comment by id; the report fills itself in
select is(pg_temp.try($$insert into reports (comment_id, reason) values ('30000000-0000-0000-0000-00000000000c', 'harassment')$$), 'ok', 'a comment can be reported');

-- the stranger sees and does nothing
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is((select count(*)::text from photo_comments), '0', 'a stranger sees no comments');
select is((select count(*)::text from photo_likes), '0', 'or likes');
select is(pg_temp.try($$insert into photo_likes (photo_id) values ('20000000-0000-0000-0000-000000000001')$$), 'refused', 'a stranger likes a photo they can''t see');
select is(pg_temp.try($$insert into photo_comments (photo_id, body) values ('20000000-0000-0000-0000-000000000001','hi')$$), 'refused', 'a stranger comments on a photo they can''t see');

-- kevin, the owner, sees both comments and removes jules's
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::text from photo_comments where photo_id = '20000000-0000-0000-0000-000000000001'), '2', 'the owner sees every comment');
select is(pg_temp.try($$delete from photo_comments where id = '30000000-0000-0000-0000-00000000000c'$$), 'ok', 'the owner removes a comment on their batch');
reset role;
select is((select reported_user_id::text || ' ' || photo_id::text || ' ' || (context->>'comment_body') from reports where comment_id is null and context->>'comment_body' is not null), '00000000-0000-0000-0000-00000000000c 20000000-0000-0000-0000-000000000001 Where is this?', 'the report kept the comment, its author and its photo after it was deleted');
set local role authenticated;

-- maya removes her own comment and like
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.try($$delete from photo_likes where photo_id = '20000000-0000-0000-0000-000000000001'$$), 'ok', 'a follower unlikes');
-- then deletes her account: her comments go with it
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select lives_ok($$select public.delete_account()$$, 'maya deletes her account');
reset role;
select is((select count(*)::text from photo_comments where author_id = '00000000-0000-0000-0000-00000000000b'), '0', 'her comments are gone');
-- and deleting the photo takes its likes and comments
delete from photos where id = '20000000-0000-0000-0000-000000000001';
select is((select count(*)::text from photo_likes where photo_id = '20000000-0000-0000-0000-000000000001'), '0', 'likes go with the photo');
select * from finish();
rollback;
