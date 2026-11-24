-- One print file per book order, for Gelato (docs/photobook-plan.md, phase 5b).
--
-- Gelato takes a photo book as a single PDF: the cover sheet, a blank endpaper, the pages and a
-- blank last page. Orders now point at that one file in print_path; interior_path and cover_path
-- stay for anything requested before, and are no longer required. Gelato's books also start at
-- 30 pages, so orders do too.

alter table book_orders add column print_path text;
alter table book_orders alter column interior_path drop not null;
alter table book_orders alter column cover_path drop not null;
alter table book_orders add constraint book_orders_has_files
  check (print_path is not null or (interior_path is not null and cover_path is not null));

alter table book_orders drop constraint book_orders_page_count_check;
alter table book_orders add constraint book_orders_page_count_check
  check (page_count between 30 and 200 and page_count % 2 = 0) not valid;

drop policy "owners order their books" on book_orders;
create policy "owners order their books" on book_orders for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from books b where b.id = book_id and b.owner_id = (select auth.uid()))
              and (print_path is null or print_path like (select auth.uid())::text || '/%')
              and (interior_path is null or interior_path like (select auth.uid())::text || '/%')
              and (cover_path is null or cover_path like (select auth.uid())::text || '/%'));

grant insert (print_path) on book_orders to authenticated;
