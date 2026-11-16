-- Photobooks: one or more batches laid out as a printed book (docs/photobook-plan.md).
--
-- A book is one JSON document owned by one person. It may use any photo its owner can see,
-- friends' included; the document only names photo ids, and the photos and their shared copies
-- stay behind the existing visibility rules. Additive: nothing older reads these tables.

-- Books ---------------------------------------------------------------------------------------

create table books (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references profiles on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  format text not null default 'square8' check (format in ('square8')),
  -- The layout: pages, items and chapters. Capped so a hand-made document can't grow without end.
  doc jsonb not null check (jsonb_typeof(doc) = 'object' and pg_column_size(doc) <= 524288),
  -- Goes up by one on every save, so a save from a stale tab can be refused (where revision = n).
  revision int not null default 0,
  status text not null default 'draft' check (status in ('draft', 'ordered')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index books_owner_idx on books (owner_id, updated_at desc);

create or replace function private.bump_book_revision() returns trigger
language plpgsql set search_path = public as $$
begin
  new.revision := old.revision + 1;
  new.updated_at := now();
  return new;
end $$;
revoke execute on function private.bump_book_revision() from public, anon, authenticated;
create trigger books_bump_revision before update on books
  for each row execute function private.bump_book_revision();

alter table books enable row level security;
create policy "owners read books" on books for select to authenticated using (owner_id = (select auth.uid()));
create policy "owners create books" on books for insert to authenticated with check (owner_id = (select auth.uid()));
create policy "owners edit books" on books for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "owners delete books" on books for delete to authenticated using (owner_id = (select auth.uid()));
-- Supabase grants every table to anon and authenticated by default, so start from nothing.
-- status is set by ordering, not by the client.
revoke all on books from anon, authenticated;
grant select, delete on books to authenticated;
grant insert (id, owner_id, title, format, doc) on books to authenticated;
grant update (title, format, doc) on books to authenticated;

-- Which batches a book uses ------------------------------------------------------------------
-- Kept in step with the document's chapters by the client. Only batches the book's owner can see.

create table book_batches (
  book_id uuid references books on delete cascade,
  collection_id uuid references collections on delete cascade,
  position int not null default 0,
  primary key (book_id, collection_id)
);
create index book_batches_collection_idx on book_batches (collection_id);

alter table book_batches enable row level security;
create policy "owners see their books' batches" on book_batches for select to authenticated
  using (exists (select 1 from books b where b.id = book_id and b.owner_id = (select auth.uid())));
create policy "owners add batches they can see" on book_batches for insert to authenticated
  with check (exists (select 1 from books b where b.id = book_id and b.owner_id = (select auth.uid()))
              and exists (select 1 from collections c where c.id = collection_id and private.can_view_collection(c)));
create policy "owners reorder their books' batches" on book_batches for update to authenticated
  using (exists (select 1 from books b where b.id = book_id and b.owner_id = (select auth.uid())));
create policy "owners remove their books' batches" on book_batches for delete to authenticated
  using (exists (select 1 from books b where b.id = book_id and b.owner_id = (select auth.uid())));
revoke all on book_batches from anon, authenticated;
grant select, delete on book_batches to authenticated;
grant insert (book_id, collection_id, position) on book_batches to authenticated;
grant update (position) on book_batches to authenticated;

-- Orders --------------------------------------------------------------------------------------
-- A request for printed copies of one revision of a book, with its print files. Payment and the
-- printer come later; until then status moves on only from the dashboard or a service-role function.

create table book_orders (
  id uuid primary key default gen_random_uuid(),
  book_id uuid references books on delete set null,
  user_id uuid not null default auth.uid() references profiles on delete cascade,
  book_revision int not null,
  quantity int not null default 1 check (quantity between 1 and 20),
  interior_path text not null,
  cover_path text not null,
  page_count int not null check (page_count between 20 and 200 and page_count % 2 = 0),
  status text not null default 'requested' check (status in ('requested', 'paid', 'printing', 'shipped', 'cancelled')),
  created_at timestamptz not null default now()
);
create index book_orders_user_idx on book_orders (user_id, created_at desc);
create index book_orders_book_idx on book_orders (book_id);

alter table book_orders enable row level security;
create policy "people see their own orders" on book_orders for select to authenticated using (user_id = (select auth.uid()));
create policy "owners order their books" on book_orders for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from books b where b.id = book_id and b.owner_id = (select auth.uid()))
              and interior_path like (select auth.uid())::text || '/%'
              and cover_path like (select auth.uid())::text || '/%');
revoke all on book_orders from anon, authenticated;
grant select on book_orders to authenticated;
grant insert (id, book_id, user_id, book_revision, quantity, interior_path, cover_path, page_count) on book_orders to authenticated;

-- Print files ---------------------------------------------------------------------------------
-- The finished PDFs, made in the browser from shared copies. Private, PDF only, in the maker's
-- own folder: {user}/{book}/{revision}/{interior|cover}.pdf.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('prints', 'prints', false, 52428800, array['application/pdf'])
on conflict (id) do nothing;

create policy "upload own print files" on storage.objects for insert to authenticated
  with check (bucket_id = 'prints' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "replace own print files" on storage.objects for update to authenticated
  using (bucket_id = 'prints' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "read own print files" on storage.objects for select to authenticated
  using (bucket_id = 'prints' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "delete own print files" on storage.objects for delete to authenticated
  using (bucket_id = 'prints' and (storage.foldername(name))[1] = (select auth.uid())::text);
