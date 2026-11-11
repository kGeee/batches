-- A batch's font and board, and each person's desk arrangement, checked as each person. Run like
-- visibility.test.sql; everything is rolled back.
--
-- People: kevin (a) owns the batch, maya (b) can add to it, jules (c) can only look, stranger (e).
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);
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

-- Build 7 writes a batch without naming the new columns, so that has to keep working.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is(pg_temp.try($$insert into collections (id, owner_id, title, frame, visibility) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','Trip','{}','people')$$), 'ok', 'build 7 creates a batch without font or board');
select is((select coalesce(font, 'none') || ' ' || coalesce(board::text, 'none') from collections where id = '10000000-0000-0000-0000-000000000001'), 'none none', 'font and board start empty');
insert into collection_members (collection_id, user_id, can_add) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000b', true), ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000c', false);

-- The owner sets them
select is(pg_temp.try($$update collections set font = 'typewriter' where id = '10000000-0000-0000-0000-000000000001'$$), 'ok', 'owner sets the font');
select is(pg_temp.try($$update collections set font = 'comic-sans' where id = '10000000-0000-0000-0000-000000000001'$$), 'refused', 'a font the app doesn''t know is refused');
select is(pg_temp.try($$update collections set board = '{"isOn":true,"placements":{}}' where id = '10000000-0000-0000-0000-000000000001'$$), 'ok', 'owner sets the board');
select is(pg_temp.try($$update collections set board = '[1,2]' where id = '10000000-0000-0000-0000-000000000001'$$), 'refused', 'a board that isn''t an object is refused');
select is(pg_temp.try($$update collections set title = 'Trip 2', frame = '{"kind":"none"}' where id = '10000000-0000-0000-0000-000000000001'$$), 'ok', 'build 7 still updates its own columns');
select is((select font || ' ' || (board->>'isOn') from collections where id = '10000000-0000-0000-0000-000000000001'), 'typewriter true', 'and that leaves font and board as they were');
select is(pg_temp.try($$insert into collections (id, owner_id, title, frame, visibility, font, board) values ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000000a','Second','{}','private','didot','{"isOn":true,"placements":{}}')$$), 'ok', 'owner creates a batch with font and board');

-- Everyone who can open the batch sees them; only the owner changes them
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select is((select font || ' ' || (board->>'isOn') from collections where id = '10000000-0000-0000-0000-000000000001'), 'typewriter true', 'viewer sees the font and board');
select is(pg_temp.try($$update collections set font = 'futura' where id = '10000000-0000-0000-0000-000000000001'$$), '0 rows', 'viewer changes the font');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is((select font from collections where id = '10000000-0000-0000-0000-000000000001'), 'typewriter', 'contributor sees the font');
select is(pg_temp.try($$update collections set board = '{"isOn":false}' where id = '10000000-0000-0000-0000-000000000001'$$), '0 rows', 'contributor changes the board');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is((select count(*)::text from collections where id = '10000000-0000-0000-0000-000000000001'), '0', 'stranger can''t see the batch');
select is(pg_temp.try($$update collections set font = 'futura' where id = '10000000-0000-0000-0000-000000000001'$$), '0 rows', 'stranger changes the font');

-- A desk belongs to the person whose it is
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is(pg_temp.try($$insert into desk_layouts (owner_id, layout) values ('00000000-0000-0000-0000-00000000000a','{"mode":"freehand"}')$$), 'ok', 'kevin saves his desk');
select is(pg_temp.try($$insert into desk_layouts (owner_id, layout) values ('00000000-0000-0000-0000-00000000000b','{"mode":"grid"}')$$), 'refused', 'kevin saves a desk as maya');
select is(pg_temp.try($$insert into desk_layouts (owner_id, layout) values ('00000000-0000-0000-0000-00000000000a','[]') on conflict (owner_id) do update set layout = excluded.layout$$), 'refused', 'a desk that isn''t an object is refused');
select is(pg_temp.try($$update desk_layouts set layout = '{"mode":"sideways"}' where owner_id = '00000000-0000-0000-0000-00000000000a'$$), 'ok', 'kevin changes his desk');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::text from desk_layouts), '0', 'maya can''t read kevin''s desk');
select is(pg_temp.try($$update desk_layouts set layout = '{}' where owner_id = '00000000-0000-0000-0000-00000000000a'$$), '0 rows', 'maya changes kevin''s desk');
select is(pg_temp.try($$delete from desk_layouts where owner_id = '00000000-0000-0000-0000-00000000000a'$$), '0 rows', 'maya deletes kevin''s desk');
reset role;
set local role anon;
select is(pg_temp.try($$select * from desk_layouts$$), 'refused', 'signed out, desks can''t be read');
reset role;
-- Deleting the account takes the desk with it
delete from profiles where id = '00000000-0000-0000-0000-00000000000a';
select is((select count(*)::text from desk_layouts where owner_id = '00000000-0000-0000-0000-00000000000a'), '0', 'the desk goes with the profile');
select * from finish();
rollback;
