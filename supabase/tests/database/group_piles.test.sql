-- Group piles: who can add, edit and remove photos in a pile shared with can_add, checked as
-- each person. Run like visibility.test.sql; everything is rolled back.
--
-- People: kevin (a) owns the pile, maya (b) can add, jules (c) can only look, stranger (e).
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);
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
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000c','jules','J');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000e','stranger','X');
-- kevin's pile, shared with maya (can add) and jules (view only), one photo of kevin's
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into collections (id, owner_id, title, frame, visibility) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','Trip','{}','people');
insert into collection_members (collection_id, user_id, can_add) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000b', true), ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000c', false);
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, share_path) values ('20000000-0000-0000-0000-00000000000a','10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-00000000000a/r1')$$), 'ok', 'owner adds own photo (added_by null)');
-- maya contributes
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, added_by, share_path) values ('20000000-0000-0000-0000-00000000000b','10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-00000000000b/r1')$$), 'ok', 'contributor adds as herself');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, added_by) values (gen_random_uuid(),'10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000a')$$), 'refused', 'contributor adds as the owner');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height) values (gen_random_uuid(),'10000000-0000-0000-0000-000000000001',3,2)$$), 'refused', 'contributor adds with no adder');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, added_by, share_path) values ('20000000-0000-0000-0000-0000000000bb','10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000bb/r1')$$), 'refused', 'contributor points copies at the owner''s folder');
select is(pg_temp.try($$update photos set caption = 'mine' where id = '20000000-0000-0000-0000-00000000000b'$$), 'ok', 'contributor captions her own photo');
select is(pg_temp.try($$update photos set caption = 'x' where id = '20000000-0000-0000-0000-00000000000a'$$), '0 rows', 'contributor edits the owner''s photo');
select is(pg_temp.try($$delete from photos where id = '20000000-0000-0000-0000-00000000000a'$$), '0 rows', 'contributor removes the owner''s photo');
select is(pg_temp.try($$update collections set title = 'Mine' where id = '10000000-0000-0000-0000-000000000001'$$), '0 rows', 'contributor renames the pile');
select is(pg_temp.try($$update collection_members set can_add = true where user_id = '00000000-0000-0000-0000-00000000000c'$$), '0 rows', 'contributor changes who else can add');
-- jules can only look
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, added_by) values (gen_random_uuid(),'10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000c')$$), 'refused', 'viewer adds a photo');
select is((select count(*)::text from photos where collection_id = '10000000-0000-0000-0000-000000000001'), '2', 'viewer sees both photos');
-- stranger
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, added_by) values (gen_random_uuid(),'10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000e')$$), 'refused', 'stranger adds a photo');
select is((select count(*)::text from photos where collection_id = '10000000-0000-0000-0000-000000000001'), '0', 'stranger sees photos');
-- owner reorders, tries to take over maya's photo, then saves the whole pile the way the app does
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is(pg_temp.try($$update photos set sort_index = 5 where id = '20000000-0000-0000-0000-00000000000b'$$), 'ok', 'owner reorders the contributor''s photo');
update photos set added_by = '00000000-0000-0000-0000-00000000000a', share_path = '00000000-0000-0000-0000-00000000000a/x/r9' where id = '20000000-0000-0000-0000-00000000000b';
select is((select added_by::text || ' ' || share_path from photos where id = '20000000-0000-0000-0000-00000000000b'), '00000000-0000-0000-0000-00000000000b 00000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-00000000000b/r1', 'authorship and copies survive the owner''s update');
select is((select sort_index::text from photos where id = '20000000-0000-0000-0000-00000000000b'), '5', 'sort order still changed');
select is(pg_temp.try($$update collection_members set can_add = false where user_id = '00000000-0000-0000-0000-00000000000b'$$), 'ok', 'owner turns can_add off');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.try($$insert into photos (id, collection_id, pixel_width, pixel_height, added_by) values (gen_random_uuid(),'10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000b')$$), 'refused', 'former contributor can''t add more');
select is(pg_temp.try($$delete from photos where id = '20000000-0000-0000-0000-00000000000b'$$), 'ok', 'former contributor still removes her own');
-- storage: owner may delete copies of a contributor's photo in their pile. Supabase refuses plain
-- SQL deletes on storage.objects unless this is set, as its Storage API does.
set local storage.allow_delete_query = 'true';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
reset role;
insert into storage.objects (bucket_id, name) values ('media','00000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000cc/r1/l.heic');
insert into photos (id, collection_id, pixel_width, pixel_height, added_by, share_path) values ('20000000-0000-0000-0000-0000000000cc','10000000-0000-0000-0000-000000000001',3,2,'00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000cc/r1');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is(pg_temp.try($$delete from storage.objects where name like '00000000-0000-0000-0000-00000000000b/%'$$), '0 rows', 'stranger deletes a contributor''s copy');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is(pg_temp.try($$delete from storage.objects where name like '00000000-0000-0000-0000-00000000000b/%'$$), 'ok', 'owner deletes a contributor''s copy in their pile');
reset role;
select * from finish();
rollback;
