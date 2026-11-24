-- Postcards, checked as each person. Run like visibility.test.sql; everything is rolled back.
--
-- People: kevin (a) has a followers batch and a private one, maya (b) follows him, stranger (e)
-- sees nothing of his.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a'),('00000000-0000-0000-0000-00000000000b'),('00000000-0000-0000-0000-00000000000e');
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
create function pg_temp.try(q text) returns text language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return case when n = 0 then '0 rows' else 'ok' end;
exception when insufficient_privilege or check_violation then return 'refused'; end $$;
grant execute on function pg_temp.as_user(text), pg_temp.try(text) to authenticated;
insert into profiles (id, handle, display_name) values
  ('00000000-0000-0000-0000-00000000000a','kevin','K'), ('00000000-0000-0000-0000-00000000000b','maya','M'), ('00000000-0000-0000-0000-00000000000e','stranger','X');
insert into collections (id, owner_id, title, visibility) values
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','Big Sur','followers'),
  ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000000a','Private','private');
insert into photos (id, collection_id, pixel_width, pixel_height, added_by) values
  ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',4000,3000,'00000000-0000-0000-0000-00000000000a'),
  ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002',4000,3000,'00000000-0000-0000-0000-00000000000a');
insert into follows (follower_id, followee_id) values ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a');
create function pg_temp.card(photo text, folder text, extra text default '') returns text language sql as $$
  select format($q$insert into postcards (photo_id, message, to_name, to_line1, to_city, to_state, to_zip, front_path, back_path%s)
    values (%L, 'Wish you were here', 'Ana Ruiz', '1 Main St', 'Oakland', 'CA', '94612', %L, %L%s)$q$,
    case when extra = '' then '' else ', status' end, photo, folder || '/front.pdf', folder || '/back.pdf',
    case when extra = '' then '' else ', ' || quote_literal(extra) end) $$;
grant execute on function pg_temp.card(text, text, text) to authenticated;
set local role authenticated;

-- maya sends kevin's photo
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.try(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b/postcards/1')), 'ok', 'maya sends a photo she can see');
select is((select user_id::text || ' ' || status from postcards), '00000000-0000-0000-0000-00000000000b requested', 'it''s hers, requested');
select is(pg_temp.try(pg_temp.card('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000b/postcards/2')), 'refused', 'but not one from a batch she can''t see');
select is(pg_temp.try(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a/postcards/3')), 'refused', 'or with files from someone else''s folder');
select is(pg_temp.try(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b/postcards/4', 'paid')), 'refused', 'she can''t mark a card paid');
select is(pg_temp.try($$update postcards set status = 'paid'$$), 'refused', 'or change one after');
select is(pg_temp.try(replace(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b/postcards/5'), '''CA''', '''California''')), 'refused', 'a state has to be two letters');
select is(pg_temp.try(replace(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b/postcards/6'), '''94612''', '''9461''')), 'refused', 'and a ZIP five digits');
select is(pg_temp.try(replace(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b/postcards/7'), 'Wish you were here', repeat('x', 351))), 'refused', 'a message runs to 350 characters');

-- kevin, whose photo it is, and the stranger see none of it
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from postcards), 0, 'kevin doesn''t see maya''s card or its address');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is(pg_temp.try(pg_temp.card('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000e/postcards/8')), 'refused', 'a stranger can''t send kevin''s photo');
select * from finish();
rollback;
