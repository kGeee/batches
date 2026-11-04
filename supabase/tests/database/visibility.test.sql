-- Who can see which pile, checked as each person through row level security.
-- Run with `supabase test db` (local) or `supabase test db --linked`. Everything runs in one
-- transaction and is rolled back, so it leaves nothing behind.
--
-- People: kevin (a), maya (b), jules (c), theo (d), stranger (e), f (bad handle).
-- Follows: kevin -> maya, maya -> kevin, theo -> kevin, jules -> maya.
begin;
create extension if not exists pgtap with schema extensions;
select plan(38);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'k@strewn.test'), ('00000000-0000-0000-0000-00000000000b', 'm@strewn.test'),
  ('00000000-0000-0000-0000-00000000000c', 'j@strewn.test'), ('00000000-0000-0000-0000-00000000000d', 't@strewn.test'),
  ('00000000-0000-0000-0000-00000000000e', 'x@strewn.test'), ('00000000-0000-0000-0000-00000000000f', 'y@strewn.test');

-- Acts as one person, like a request carrying their JWT.
create function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true)
$$;
-- Titles of the piles the current person can see, alphabetically.
create function pg_temp.seen() returns text language sql as $$
  select coalesce(string_agg(title, ', ' order by title), '') from collections
$$;
grant execute on function pg_temp.as_user(text), pg_temp.seen() to authenticated, anon;

set local role authenticated;

-- Profiles ----------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000a', 'kevin', 'Kevin');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000b', 'maya.r', 'Maya');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000c', 'jules', 'Jules');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000d', 'theo_shoots', 'Theo');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e'); insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000e', 'stranger', 'X');
select is((select count(*)::int from profiles), 5, 'each person creates their own profile');

select throws_ok($$ insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000e', 'kevin', 'dup') $$,
                 '23505', null, 'a second profile for the same account is refused');
select throws_ok($$ insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000a', 'other', 'X') $$,
                 '42501', null, 'nobody creates a profile for someone else');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000f');
select throws_ok($$ insert into profiles (id, handle, display_name) values ('00000000-0000-0000-0000-00000000000f', 'No Caps', 'Y') $$,
                 '23514', null, 'handles are lowercase letters, digits, _ and .');
select throws_ok($$ update profiles set follower_count = 999 where id = '00000000-0000-0000-0000-00000000000a' $$,
                 '42501', null, 'follower counts are not writable by clients');

-- Follows -----------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a'); insert into follows values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b'); insert into follows values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d'); insert into follows values ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c'); insert into follows values ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$ insert into follows values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000c') $$,
                 '42501', null, 'nobody follows as someone else');
select throws_ok($$ insert into follows values ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-00000000000c') $$,
                 '23514', null, 'nobody follows themselves');

-- Kevin's piles: bigsur (followers), joshua (people: maya), fog (private) ---------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into collections (id, owner_id, title, visibility) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'bigsur', 'followers'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'joshua', 'people'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000a', 'fog', 'private');
insert into collection_members values ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000b');
insert into photos (id, collection_id, pixel_width, pixel_height, share_path) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 3000, 2000,
   '00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/r1');
update collections set cover_photo_id = '20000000-0000-0000-0000-000000000001' where id = '10000000-0000-0000-0000-000000000002';
select lives_ok($$ insert into storage.objects (bucket_id, name) values
                   ('media', '00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/r1/l.heic') $$,
                'owners upload shared copies to their own folder');

select throws_ok($$ insert into photos (id, collection_id, pixel_width, pixel_height, share_path) values
                    ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 3000, 2000,
                     '00000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-000000000002/r1') $$,
                 '42501', null, 'share_path must be in the owner''s folder');
select throws_ok($$ insert into photos (id, collection_id, pixel_width, pixel_height, share_path) values
                    ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 3000, 2000,
                     '00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000009/r1') $$,
                 '42501', null, 'share_path must name the photo''s own id');
select throws_ok($$ update collections set like_count = 999 where id = '10000000-0000-0000-0000-000000000001' $$,
                 '42501', null, 'like counts are not writable by clients');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('media', '00000000-0000-0000-0000-00000000000b/x/r1/l.heic') $$,
                 '42501', null, 'nobody uploads into someone else''s folder');

-- Maya's piles, and what she can't do to Kevin's ---------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
insert into collections (id, owner_id, title, visibility) values
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000b', 'tomales', 'followers'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000b', 'nightmarket', 'followers');
with changed as (update collections set title = 'mine now' where id = '10000000-0000-0000-0000-000000000001' returning 1)
select is(count(*)::int, 0, 'maya can''t rename kevin''s pile') from changed;
with gone as (delete from collections where id = '10000000-0000-0000-0000-000000000001' returning 1)
select is(count(*)::int, 0, 'maya can''t delete kevin''s pile') from gone;
select throws_ok($$ insert into collection_members values ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000b') $$,
                 '42501', null, 'maya can''t share kevin''s pile with herself');
select throws_ok($$ insert into collections (owner_id, title) values ('00000000-0000-0000-0000-00000000000a', 'fake') $$,
                 '42501', null, 'maya can''t make a pile as kevin');

-- Theo: mono (people: kevin). Jules: desert (public), contact (private). ----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
insert into collections (id, owner_id, title, visibility) values ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000d', 'mono', 'people');
insert into collection_members values ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
insert into collections (id, owner_id, title, visibility) values
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-00000000000c', 'desert', 'public'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-00000000000c', 'contact', 'private');

-- What each person sees ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), 'bigsur, desert, fog, joshua, mono, nightmarket, tomales', 'kevin: his own, shared with him, public, followed');
select is((select count(*)::int from storage.objects where bucket_id = 'media'), 1, 'kevin sees his own shared copy');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.seen(), 'bigsur, desert, joshua, nightmarket, tomales', 'maya: followers pile, the one shared with her, public, her own');
select is((select count(*)::int from photos), 1, 'maya sees the photo in the pile shared with her');
select is((select count(*)::int from storage.objects where bucket_id = 'media'), 1, 'maya can read its shared copy');
select is((select count(*)::int from collection_members), 1, 'maya sees only her own share, not the rest of kevin''s list');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select is(pg_temp.seen(), 'contact, desert, nightmarket, tomales', 'jules: no kevin piles (doesn''t follow him)');
select is((select count(*)::int from photos) + (select count(*)::int from storage.objects where bucket_id = 'media'), 0,
          'jules sees no photos or copies');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select is(pg_temp.seen(), 'bigsur, desert, mono', 'theo: follows kevin, so bigsur, but not joshua or fog');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is(pg_temp.seen(), 'desert', 'stranger: only the public pile');

-- A followers pile also shows to people it's shared with directly.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into collection_members values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000e');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select is(pg_temp.seen(), 'bigsur, desert', 'stranger sees a followers pile shared with them');

reset role;
set local role anon;
select throws_ok($$ select count(*) from collections $$, '42501', null, 'signed-out requests read nothing');
reset role;
set local role authenticated;

-- Counts kept by triggers --------------------------------------------------------------------------
select results_eq($$ select handle, follower_count, following_count from profiles order by handle $$,
  $$ values ('jules', 0, 1), ('kevin', 2, 1), ('maya.r', 2, 1), ('stranger', 0, 0), ('theo_shoots', 0, 1) $$,
  'follower and following counts follow the follows');

-- Owner edits, unfollow, unshare --------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select results_eq($$ update collections set visibility = 'public', title = 'bigsur2' where id = '10000000-0000-0000-0000-000000000001' returning title, visibility::text $$,
  $$ values ('bigsur2', 'public') $$, 'kevin edits his own pile');
select results_eq($$ insert into collections (id, owner_id, title, visibility) values ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000a', 'fog', 'people')
                     on conflict (id) do update set title = excluded.title, visibility = excluded.visibility returning title, visibility::text $$,
  $$ values ('fog', 'people') $$, 'kevin upserts his own pile, as the app saves');
delete from follows where followee_id = '00000000-0000-0000-0000-00000000000b';
select is(pg_temp.seen(), 'bigsur2, desert, fog, joshua, mono', 'after unfollowing maya, kevin no longer sees her followers piles');
select is((select follower_count from profiles where handle = 'maya.r'), 1, 'unfollowing only removed kevin''s own follow');

select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
with gone as (delete from collection_members where collection_id = '10000000-0000-0000-0000-000000000002' returning 1)
select is(count(*)::int, 0, 'only the owner changes who a pile is shared with') from gone;
select is(pg_temp.seen(), 'bigsur2, desert, joshua, nightmarket, tomales', 'maya after: bigsur2 is public now, joshua still shared');

select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
with gone as (delete from collection_members where collection_id = '10000000-0000-0000-0000-000000000002' returning 1)
select is(count(*)::int, 1, 'kevin unshares joshua') from gone;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.seen(), 'bigsur2, desert, nightmarket, tomales', 'maya no longer sees joshua');
select is((select count(*)::int from storage.objects where bucket_id = 'media'), 0, 'or its shared copy');

select * from finish();
rollback;
