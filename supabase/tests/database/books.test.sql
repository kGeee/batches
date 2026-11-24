-- Photobooks, checked as each person. Run like visibility.test.sql; everything is rolled back.
--
-- People: kevin (a) owns a followers batch and a private one, maya (b) follows him and makes a
-- book from his followers batch, stranger (e) sees nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(28);
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a'),('00000000-0000-0000-0000-00000000000b'),('00000000-0000-0000-0000-00000000000e');
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
-- What a statement did: 'ok', '0 rows' (filtered out by a policy) or 'refused' (blocked).
create function pg_temp.try(q text) returns text language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return case when n = 0 then '0 rows' else 'ok' end;
exception when insufficient_privilege or check_violation then return 'refused'; end $$;
grant execute on function pg_temp.as_user(text), pg_temp.try(text) to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000a','kevin','K');
insert into collections (id, owner_id, title, visibility) values
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','Big Sur','followers'),
  ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000000a','Private','private');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000b','maya','M');
insert into follows (follower_id, followee_id) values ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000e','stranger','X');

-- maya makes a book from kevin's batch
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.try($$insert into books (id, title, doc) values ('50000000-0000-0000-0000-000000000001','California','{"v":1}')$$), 'ok', 'maya makes a book');
select is((select owner_id::text || ' ' || revision || ' ' || status from books), '00000000-0000-0000-0000-00000000000b 0 draft', 'it''s hers, a draft at revision 0');
select is(pg_temp.try($$insert into books (title, doc, owner_id) values ('Fake','{}','00000000-0000-0000-0000-00000000000a')$$), 'refused', 'she can''t make a book as kevin');
select is(pg_temp.try($$insert into books (title, doc) values ('   ','{}')$$), 'refused', 'a blank title is refused');
select is(pg_temp.try($$insert into books (title, doc) values ('List','[]')$$), 'refused', 'the document has to be an object');
select is(pg_temp.try($$insert into books (title, doc, format) values ('Big','{}','poster')$$), 'refused', 'an unknown format is refused');
select is(pg_temp.try($$insert into book_batches (book_id, collection_id) values ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001')$$), 'ok', 'she adds a friend''s batch she can see');
select is(pg_temp.try($$insert into book_batches (book_id, collection_id) values ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002')$$), 'refused', 'but not one she can''t');

-- saving bumps the revision, so a stale save can match nothing
select is(pg_temp.try($$update books set doc = '{"v":1,"pages":[]}' where id = '50000000-0000-0000-0000-000000000001' and revision = 0$$), 'ok', 'a save at the current revision lands');
select is((select revision from books where id = '50000000-0000-0000-0000-000000000001'), 1, 'and bumps the revision');
select is(pg_temp.try($$update books set doc = '{"v":1}' where id = '50000000-0000-0000-0000-000000000001' and revision = 0$$), '0 rows', 'a save from a stale tab matches nothing');
select is(pg_temp.try($$update books set status = 'ordered' where id = '50000000-0000-0000-0000-000000000001'$$), 'refused', 'she can''t mark it ordered herself');
select is(pg_temp.try($$update books set revision = 40 where id = '50000000-0000-0000-0000-000000000001'$$), 'refused', 'or set the revision');

-- ordering
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/x/1/book.pdf', 30)$$), 'ok', 'she requests a copy with one print file');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, interior_path, cover_path, page_count) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/x/1/interior.pdf', '00000000-0000-0000-0000-00000000000b/x/1/cover.pdf', 30)$$), 'ok', 'separate interior and cover files still work');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, page_count) values ('50000000-0000-0000-0000-000000000001', 1, 30)$$), 'refused', 'an order needs a print file');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/x/1/book.pdf', 28)$$), 'refused', 'and at least 30 pages');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000a/x/1/book.pdf', 30)$$), 'refused', 'with a file from someone else''s folder');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, interior_path, cover_path, page_count) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000a/x/1/interior.pdf', '00000000-0000-0000-0000-00000000000b/x/1/cover.pdf', 30)$$), 'refused', 'or separate files from someone else''s folder');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count, status) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/a.pdf', 30, 'paid')$$), 'refused', 'she can''t mark an order paid');

select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count, ship_first_name, ship_last_name, ship_line1, ship_city, ship_state, ship_zip) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/x/1/book.pdf', 30, 'Maya', 'Lin', '1 Main St', 'Oakland', 'CA', '94612')$$), 'ok', 'she orders with a shipping address');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count, ship_first_name, ship_last_name, ship_line1, ship_city, ship_state, ship_zip) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/x/1/book.pdf', 30, 'Maya', 'Lin', '1 Main St', 'Oakland', 'California', '94612')$$), 'refused', 'a state has to be two letters');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count, gelato_order_id) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000b/x/1/book.pdf', 30, 'fake')$$), 'refused', 'she can''t say it''s at the printer');
select is(pg_temp.try($$update book_orders set quote_product_cents = 1$$), 'refused', 'or change the printer''s price');

-- kevin, whose photos are in it, and the stranger see none of it
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::text from books) || (select count(*)::text from book_batches) || (select count(*)::text from book_orders), '000', 'kevin doesn''t see maya''s book, its batches or her order');
select is(pg_temp.try($$update books set title = 'mine' where id = '50000000-0000-0000-0000-000000000001'$$), '0 rows', 'or change it');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is(pg_temp.try($$insert into book_orders (book_id, book_revision, print_path, page_count) values ('50000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000e/a.pdf', 30)$$), 'refused', 'a stranger can''t order maya''s book');

-- deleting kevin's batch takes it out of the book; deleting the book takes the rest
reset role;
delete from collections where id = '10000000-0000-0000-0000-000000000001';
select is((select count(*)::text from book_batches), '0', 'a deleted batch leaves the book');
select * from finish();
rollback;
