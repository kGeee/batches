-- Blocking, reporting and deleting an account, checked as each person. Run like
-- visibility.test.sql; everything is rolled back.
--
-- People: kevin (a), maya (b), jules (c). kevin follows maya, maya follows kevin, each has a
-- followers batch, maya's is shared with kevin, and maya added a photo to jules's public batch.
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1'),('00000000-0000-0000-0000-0000000000b1'),('00000000-0000-0000-0000-0000000000c1');
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
create function pg_temp.try(q text) returns text language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return case when n = 0 then '0 rows' else 'ok' end;
exception when insufficient_privilege or check_violation then return 'refused'; end $$;
grant execute on function pg_temp.as_user(text), pg_temp.try(text) to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000a1','t_kevin','K');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000b1','t_maya','M');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-0000000000c1','t_jules','J');
insert into collections (id, owner_id, title, frame, visibility) values ('30000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-0000000000c1','Jules public','{}','public');
insert into collection_members (collection_id, user_id, can_add) values ('30000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-0000000000b1', true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into follows values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1');
insert into collections (id, owner_id, title, frame, visibility) values ('30000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-0000000000a1','Kevin followers','{}','followers');
insert into collection_members (collection_id, user_id) values ('30000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-0000000000b1');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
insert into follows values ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000a1');
insert into collections (id, owner_id, title, frame, visibility) values ('30000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-0000000000b1','Maya followers','{}','followers');
insert into collection_members (collection_id, user_id) values ('30000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-0000000000a1');
insert into photos (id, collection_id, pixel_width, pixel_height) values ('40000000-0000-0000-0000-00000000000b','30000000-0000-0000-0000-00000000000b',3,2);
insert into photos (id, collection_id, pixel_width, pixel_height, added_by) values ('40000000-0000-0000-0000-0000000000cb','30000000-0000-0000-0000-00000000000c',3,2,'00000000-0000-0000-0000-0000000000b1');
-- before the block
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::text from collections where id = '30000000-0000-0000-0000-00000000000b'), '1', 'kevin sees maya''s batch before blocking');
select is((select count(*)::text from photos where collection_id = '30000000-0000-0000-0000-00000000000c'), '1', 'kevin sees maya''s photo in jules''s batch');
-- kevin blocks maya
select is(pg_temp.try($$insert into blocks (blocker_id, blocked_id) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1')$$), 'ok', 'kevin blocks maya');
select is(pg_temp.try($$insert into blocks (blocker_id, blocked_id) values ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1')$$), 'refused', 'kevin blocks on maya''s behalf');
select is((select count(*)::text from blocks), '1', 'kevin sees his block');
select is((select count(*)::text from follows where '00000000-0000-0000-0000-0000000000b1' in (follower_id, followee_id)), '0', 'follows both ways are gone');
select is((select count(*)::text from collection_members where collection_id in ('30000000-0000-0000-0000-00000000000a','30000000-0000-0000-0000-00000000000b')), '0', 'shares both ways are gone');
select is((select count(*)::text from collections where id = '30000000-0000-0000-0000-00000000000b'), '0', 'kevin no longer sees maya''s batch');
select is((select count(*)::text from photos where collection_id = '30000000-0000-0000-0000-00000000000c'), '0', 'kevin no longer sees maya''s photo in jules''s batch');
select is((select count(*)::text from collections where id = '30000000-0000-0000-0000-00000000000c'), '1', 'kevin still sees jules''s batch');
select is(pg_temp.try($$insert into follows values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1')$$), 'refused', 'kevin can''t follow maya');
select is(pg_temp.try($$insert into collection_members (collection_id, user_id) values ('30000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-0000000000b1')$$), 'refused', 'kevin can''t share with maya');
-- maya's side
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select is((select count(*)::text from blocks), '0', 'maya can''t see that she''s blocked');
select is((select count(*)::text from collections where id = '30000000-0000-0000-0000-00000000000a'), '0', 'maya no longer sees kevin''s batch');
select is(pg_temp.try($$insert into follows values ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000a1')$$), 'refused', 'maya can''t follow kevin');
select is(pg_temp.try($$delete from blocks$$), '0 rows', 'maya can''t remove kevin''s block');
-- reports
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select is(pg_temp.try($$insert into reports (photo_id, reason) values ('40000000-0000-0000-0000-0000000000cb','spam')$$), 'ok', 'jules reports a photo');
select is(pg_temp.try($$select * from reports$$), 'refused', 'jules can''t read reports');
reset role;
select is((select reporter_id::text || ' ' || reported_user_id::text || ' ' || (context->>'batch_title') from reports where photo_id = '40000000-0000-0000-0000-0000000000cb'),
          '00000000-0000-0000-0000-0000000000c1 00000000-0000-0000-0000-0000000000b1 Jules public', 'the report names who reported whom, and the batch');
-- maya deletes her account
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select lives_ok($$select delete_account()$$, 'maya deletes her account');
reset role;
select is((select (select count(*) from auth.users where id = '00000000-0000-0000-0000-0000000000b1')
               + (select count(*) from collections where owner_id = '00000000-0000-0000-0000-0000000000b1')
               + (select count(*) from photos where added_by = '00000000-0000-0000-0000-0000000000b1' or id = '40000000-0000-0000-0000-00000000000b'))::text,
          '0', 'her user, batches and the photo she added to jules''s batch are gone');
select * from finish();
rollback;
