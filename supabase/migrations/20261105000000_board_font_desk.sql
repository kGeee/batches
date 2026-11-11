-- A batch's font and freehand board, and each person's own desk arrangement.
--
-- Additive on purpose: build 7 reads `*` and ignores columns it doesn't know, and its upserts name
-- their columns, so they leave these alone. The board is not in collections.frame because older
-- builds fail to decode a frame with a layout they don't know, which would sink their whole feed.
--
--   collections.font   the owner's font for the batch; null means the app's default
--   collections.board  the owner's freehand arrangement, seen by everyone who can view the batch
--   desk_layouts       how someone arranges their own desk; only they can read or change it

alter table collections
  add column font text check (font in ('classic', 'modern', 'rounded', 'typewriter', 'didot', 'futura', 'handwritten')),
  -- { "isOn": bool, "placements": { "<photo id>": { "x", "y", "width", "rotation", "z" } } }
  -- A cap well above any real batch: 60 photos at a time, about 100 bytes each.
  add column board jsonb check (jsonb_typeof(board) = 'object' and pg_column_size(board) < 262144);

-- collections has column-level grants, so new columns aren't writable until they're listed.
-- The "owners write piles" policy still decides whose rows these writes can touch.
grant insert (font, board), update (font, board) on collections to authenticated;

create table desk_layouts (
  owner_id uuid primary key references profiles on delete cascade,
  layout jsonb not null check (jsonb_typeof(layout) = 'object' and pg_column_size(layout) < 262144),
  updated_at timestamptz not null default now()
);

alter table desk_layouts enable row level security;

create policy "read own desk" on desk_layouts for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "create own desk" on desk_layouts for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy "change own desk" on desk_layouts for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "delete own desk" on desk_layouts for delete to authenticated
  using (owner_id = (select auth.uid()));

grant select, insert, update, delete on desk_layouts to authenticated;
revoke all on desk_layouts from anon;
