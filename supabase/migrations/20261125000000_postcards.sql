-- Postcards: one photo printed and mailed through Lob, with a message on the back.
-- The browser draws both sides as PDFs into the private prints bucket, then inserts a row here.
-- The postcard-send function does the rest with the service role: it reads the row, hands Lob
-- short-lived links to the two files, and records what Lob answered. Nobody but that function can
-- change a row, so a card can't mark itself paid or sent.

create table postcards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  photo_id uuid references photos on delete set null,
  message text not null check (char_length(message) between 1 and 350),
  to_name text not null check (char_length(to_name) between 1 and 40),
  to_line1 text not null check (char_length(to_line1) between 1 and 64),
  to_line2 text check (to_line2 is null or char_length(to_line2) <= 64),
  to_city text not null check (char_length(to_city) between 1 and 200),
  to_state text not null check (to_state ~ '^[A-Z]{2}$'),
  to_zip text not null check (to_zip ~ '^\d{5}(-\d{4})?$'),
  front_path text not null,
  back_path text not null,
  -- requested: files made, not sent. paid: paid for, ready to mail. sent: Lob has it.
  status text not null default 'requested'
    check (status in ('requested', 'paid', 'sent', 'delivered', 'returned', 'cancelled', 'failed')),
  lob_id text,
  -- 'test' cards are rendered by Lob but never mailed.
  lob_env text check (lob_env in ('test', 'live')),
  proof_url text,
  expected_delivery date,
  failure text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create index postcards_user_idx on postcards (user_id, created_at desc);

alter table postcards enable row level security;

create policy "people see their own postcards" on postcards for select to authenticated
  using (user_id = (select auth.uid()));

-- You can send a photo you can see, from files in your own folder.
create policy "people send photos they can see" on postcards for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and photo_id is not null
    and private.can_view_photo(photo_id)
    and front_path like (select auth.uid())::text || '/%'
    and back_path like (select auth.uid())::text || '/%'
  );

-- Supabase grants every table to anon and authenticated by default, so start from nothing.
revoke all on postcards from anon, authenticated;
grant select on postcards to authenticated;
grant insert (id, photo_id, message, to_name, to_line1, to_line2, to_city, to_state, to_zip, front_path, back_path)
  on postcards to authenticated;
