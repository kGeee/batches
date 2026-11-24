-- Sending a book order to Gelato (docs/photobook-plan.md, phase 5b).
--
-- An order now carries where it ships, within Gelato's limits (names 25 characters, address lines
-- 35, city 30). The book-order function quotes it with Gelato and places
-- it there, writing back what Gelato answered; nobody else can change those columns. Until
-- payment exists, orders go to Gelato as drafts, which Gelato keeps but never prints or charges.

alter table book_orders
  add column ship_first_name text check (ship_first_name is null or char_length(ship_first_name) between 1 and 25),
  add column ship_last_name text check (ship_last_name is null or char_length(ship_last_name) between 1 and 25),
  add column ship_line1 text check (ship_line1 is null or char_length(ship_line1) between 1 and 35),
  add column ship_line2 text check (ship_line2 is null or char_length(ship_line2) <= 35),
  add column ship_city text check (ship_city is null or char_length(ship_city) between 1 and 30),
  add column ship_state text check (ship_state is null or ship_state ~ '^[A-Z]{2}$'),
  add column ship_zip text check (ship_zip is null or ship_zip ~ '^\d{5}(-\d{4})?$'),
  add column ship_country text not null default 'US' check (ship_country = 'US'),
  -- What Gelato answered.
  add column quote_product_cents int,
  add column quote_shipping_cents int,
  add column quote_currency text,
  add column shipment_method text,
  add column shipment_method_name text,
  add column delivery_days text,
  add column gelato_order_id text,
  add column gelato_order_type text check (gelato_order_type in ('draft', 'order')),
  add column failure text,
  add column sent_at timestamptz;

-- 'draft': Gelato holds it as a draft. 'failed': Gelato refused it.
alter table book_orders drop constraint book_orders_status_check;
alter table book_orders add constraint book_orders_status_check
  check (status in ('requested', 'draft', 'paid', 'printing', 'shipped', 'cancelled', 'failed'));

grant insert (ship_first_name, ship_last_name, ship_line1, ship_line2, ship_city, ship_state, ship_zip)
  on book_orders to authenticated;
