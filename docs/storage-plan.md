# Batches storage plan: shared copies go to the cloud, originals stay on the phone

Prices checked on the providers' own pages on October 29, 2026 (one exception noted). Rewritten on November 3, 2026 for the app as it is now: **the camera and the editor are set aside**, so every photo comes from the person's Photos library. Nothing here beyond the interim Supabase bucket has been set up or billed.

## The short version

- **Originals never go to the cloud.** A photo added to a batch is copied into the app from the person's Photos library, and that copy stays on the phone. If they use iCloud Photos, Apple already backs up the original on their own plan, at no cost to us.
- **Other people only ever see shared copies**: HEIC in a few sizes, made on the phone when a batch is shared, with location data stripped. A full-resolution copy is optional per batch. JPEG is made only for public web share pages.
- **In a group batch, each person uploads their own photos' copies**, into their own folder. Whoever added a photo owns its copies; the batch's owner can still remove them.
- **Today:** copies go to a private Supabase Storage bucket (`media`) in three sizes, `s`, `m` and `l`, and viewers get links that expire after six hours. That's fine for TestFlight and a first launch.
- **Later: Cloudflare R2 behind Cloudflare's CDN**, with a small Worker that checks signed links for non-public batches. Supabase keeps sign-in, Postgres and the sharing rules, but not the image bytes.
- **Headline cost** (storage plus delivery plus Supabase, about a year in): about **$36/month at 1k** active users, **$110 at 10k**, **$880 at 100k** on R2. Staying on Supabase Storage costs about the same at 1k, about $225 at 10k and $2,300 at 100k.

With no RAW files and no editor, there's nothing expensive left to store per person, so the open decisions are when to move to R2 and what (if anything) to charge for. Both are at the end.

## 1. What each copy is for

| Copy | Where it lives | Who sees it | Made by |
| --- | --- | --- | --- |
| Original (HEIC or JPEG from Photos, 1.5 to 6 MB) | App container + the person's Photos library | The person who added it | Imported from Photos |
| Shared copies (HEIC, about 0.3 MB for `s`/`m`/`l`, 0.8 MB with `x`) | Supabase `media` bucket now, R2 later | Anyone allowed to see the batch | The adder's phone |
| Full-res copy (HEIC, 1.5 to 6 MB) | Same place, only if the owner turns on downloads | Viewers who tap Download | The adder's phone |
| Web copy (JPEG, about 300 KB) | Same place, only for public batches or web share links | Browsers on the web share page | The adder's phone |

Viewers never download an original. The server never touches pixels: every copy is made on a phone.

## 2. Shared-copy format

**HEIC, keeping the photo's own color profile, for everything inside the app.**

- HEIC is roughly half the size of JPEG at the same visual quality, and every iPhone decodes HEVC in hardware. ImageIO writes it directly; `ShareCopyMaker` already does, at quality 0.65 for `s` and 0.70 for `m` and `l`. Use about 0.85 for a full-res copy.
- iPhone photos are already Display P3; the copies keep that profile, so colors match what the person saw in Photos.
- 8-bit is enough for photos from the library. (10-bit only mattered for the camera's film looks, which banded at 8-bit; see section 10.)
- Strip GPS and other location metadata from every shared copy. The app already does: only pixels and the color profile go in.

**JPEG only for the web.** Chrome and Firefox don't show HEIC, so a public batch's web share page needs JPEG. Make one 1600 px JPEG (quality 0.82, Display P3 ICC profile embedded) per photo, plus a 1200 px Open Graph image for the cover, and only when the batch is public or gets a share link.

**AVIF and WebP: not for now.** As far as I could find, iOS's ImageIO decodes AVIF but has no public AVIF or WebP encoder, so using them means bundling libavif (slow and battery-hungry for big images on device) or paying for server-side transforms. HEIC already gets iOS viewers the same savings. Worth re-checking on iOS 26 with `CGImageDestinationCopyTypeIdentifiers()` before an Android or web client exists.

**HDR (gain maps):** skip for v1. Recent iPhone photos carry an HDR gain map, and copies made today drop it, so bright highlights show as standard range. A gain map can be added to the `l` and `x` copies later without changing the ladder.

## 3. Size ladder

Sizes are long-edge pixels, never cropped. Every tier keeps the photo's native aspect ratio, so the full-frame rule holds at every size. Panoramas (wider than 2.2:1) get 1.6 times the long edge so their short side stays usable.

| Tier | Long edge | Used by | HEIC quality | Size (3:2 photo) |
| --- | --- | --- | --- | --- |
| `s` | 320 | Desk batch prints, notifications | 0.65 | about 12 KB |
| `m` | 800 | Two-column masonry, sideways film roll, feed covers | 0.70 | about 55 KB |
| `l` | 1800 | Single-column gallery and feed, vertical film roll | 0.70 | about 240 KB |
| `x` | 2732 | Full-screen viewer and pinch zoom | 0.75 | about 500 KB |
| `full` | Native (12 or 48 MP) | Download, only if the owner allows it | 0.85 | 1.5 to 2.5 MB at 12 MP, about 6 MB at 48 MP |
| `web` | 1600 | Web share page (JPEG) | 0.82 | about 300 KB |

Why these sizes: the widest iPhone screen is 1320 px across, and a 3:4 portrait shown full width there is 1760 px tall, so `l` at 1800 covers the main gallery without upscaling. `x` matches the long side of the biggest phone screen plus a little zoom headroom.

**Made today:** `s`, `m` and `l` (about 0.3 MB together); the full-screen viewer uses `l`. Add `x` when sharp pinch-zoom matters.

The four in-app tiers add up to about 0.8 MB per photo, roughly a quarter of one 12 MP JPEG, and the feed mostly loads `m` and `l`.

**Client rule:** pick the smallest tier whose long edge is at least the on-screen size in pixels (points times display scale), allowing up to 15% upscale before stepping up. Decode with ImageIO thumbnails (`kCGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`) so memory matches the view, not the file.

## 4. Changing or removing a photo

With no editor, a shared photo's copies are made once and never re-rendered.

1. Adding photos to a shared batch makes their copies right away (a group batch contributor's copies upload before the photo joins the batch).
2. Sharing a batch that was private makes copies for every photo that doesn't have them yet.
3. Removing a photo deletes its copies too, whoever added it. The original stays in the person's Photos library.
4. Making a batch private again stops new links from working; links already handed out stop within six hours today (about a day with the R2 setup in section 7).

## 5. Prices checked (October 29, 2026)

| Provider | Storage | Delivery (egress) | Requests | Notes |
| --- | --- | --- | --- | --- |
| Supabase Storage (Pro, $25/mo) | 100 GB included, then $0.0213/GB | 250 GB cached + 250 GB uncached included, then $0.03 cached / $0.09 uncached per GB | Included | Image transforms: 100 origin images included, then $5 per 1,000 |
| Cloudflare R2 | $0.015/GB (IA $0.01) | Free | $4.50 per million writes, $0.36 per million reads | 10 GB, 1M writes, 10M reads free each month. IA adds $0.01/GB to read |
| Backblaze B2 | $6.95/TB (about $0.007/GB) | Free up to 3x stored, then $0.01/GB; free through Cloudflare, Bunny, Fastly | Most calls free | No minimums |
| AWS S3 + CloudFront | $0.023/GB | CloudFront: 1 TB free, then $0.085/GB (US/EU) | $0.01 per 10,000 HTTPS requests after 10M free | Flat-rate CloudFront plans ($15 / $200 / $1,000) are capped by requests (10M / 125M / 500M); figures from an AWS re:Post article, not the price page |
| Bunny Storage + CDN | $0.01/GB (one region) | $0.01/GB North America and Europe, $0.03 Asia, $0.005 on the volume network | None | $1 monthly minimum |
| Cloudflare Workers (Paid) | n/a | n/a | $5/mo includes 10M, then $0.30 per million | Used only to check signed URLs |
| Cloudflare Images | n/a | n/a | $0.50 per 1,000 transformations after 5,000 | Listed to show what server-side resizing would cost |

Sources: supabase.com/docs/pricing, developers.cloudflare.com/r2/pricing, backblaze.com/cloud-storage/pricing, bunny.net/pricing/cdn and /storage, developers.cloudflare.com/workers/platform/pricing, developers.cloudflare.com/images/pricing, supabase.com/docs/guides/platform/compute-and-disk. S3 and CloudFront rates came from third-party summaries (Upstash, Perfsys) and the re:Post article, so check aws.amazon.com before relying on them.

## 6. Monthly cost estimates

### Assumptions

- Each active user (MAU) shares 40 photos a month, about one or two batches.
- About a year in, so stored copies equal 12 months of uploads. Storage keeps growing after that, so year two roughly doubles the storage line.
- Each active user opens the app 30 times a month and sees about 40 `l`, 60 `s`/`m` and 5 `x` images per visit. The phone's own cache absorbs a quarter of that.
- The CDN serves 85% of requests from cache.
- Each photo is uploaded as 4 tiers. (The tables below were worked out with 20% extra uploads for re-edits, which no longer happen, so they run a little high: roughly 15% on the storage line.)
- No `full` or `web` copies (priced separately below).
- Supabase platform: Pro $25 plus compute, roughly Micro at 1k, Small (about $15) at 10k and Large (about $110) at 100k. Compute is a guess at load, not a measurement.

That works out to:

| | 1k MAU | 10k MAU | 100k MAU |
| --- | --- | --- | --- |
| Shared copies stored | 0.4 TB | 3.9 TB | 39 TB |
| Delivered per month | 0.35 TB | 3.5 TB | 35 TB |
| CDN requests per month | 2.4M | 24M | 236M |

### Storage plus delivery, by provider

| Setup | 1k MAU | 10k MAU | 100k MAU |
| --- | --- | --- | --- |
| **R2 + Cloudflare CDN + signing Worker (recommended)** | **$11** | **$71** | **$747** |
| R2 + CDN, no Worker (unguessable URLs only) | $6 | $62 | $674 |
| Backblaze B2 + Bunny CDN | $8 | $79 | $790 |
| Bunny Storage + Bunny CDN | $9 | $91 | $909 |
| Supabase Storage + its CDN | $7 | $186 | $2,147 |
| S3 + CloudFront flat-rate plan | $25 | $299 | $1,990 |
| S3 + CloudFront pay as you go | $10 | $322 | $3,953 |

### Total with the recommended setup

| | 1k MAU | 10k MAU | 100k MAU |
| --- | --- | --- | --- |
| R2, CDN and Worker | $11 | $71 | $747 |
| Supabase (Pro + compute) | $25 | about $40 | about $135 |
| **Total** | **about $36** | **about $110** | **about $880** |
| Per active user | $0.036 | $0.011 | $0.009 |

At 100k the R2 bill is mostly storage ($580 of $747), so it grows with time even if users don't: about $0.015 per GB-month, or roughly $0.006 per active user for each year of photos they've shared.

### Add-ons, priced on the same assumptions

- **Full-res downloads**, if owners turn them on for 20% of photos: adds about 45% to stored bytes (about $260/month more at 100k) and almost nothing to delivery, since downloads are rare.
- **Server-side resizing instead of on-device:** Supabase transforms would cost about $200, $2,000 and $20,000 a month; Cloudflare Images about $80, $800 and $8,000. Making the copies on the phone, as the app already does, avoids that entirely.

## 7. Recommended setup

**Storage and delivery**
- One R2 bucket for shared copies, on a custom domain (for example `img.strewn.app`) with a "cache everything" rule and Tiered Cache turned on to raise the hit rate.
- Object keys are immutable: `m/{adder_id}/{photo_id}/{rev}/{tier}.heic`, the same shape the Supabase bucket uses now, so moving is a copy plus one host setting. In a group batch `adder_id` is whoever added the photo. Serve them with `Cache-Control: public, max-age=31536000, immutable`, so neither the CDN nor the phone ever re-checks them.
- R2 lifecycle rules: abort incomplete multipart uploads after 1 day; nothing else, since deletes are handled by the queue in `storage.sql`.

**Privacy for non-public batches**
- A Postgres function (`signed_media_paths` in `storage.sql`) checks `can_view_collection`, then returns each photo's tier paths with an expiry and an HMAC signature, using a secret kept in Supabase Vault.
- A Cloudflare Worker on the image domain checks the signature and expiry, then serves from the CDN cache or R2. The cache key is the path without the signature, so one cached copy serves every allowed viewer.
- Expiry is rounded to the end of the next day so URLs stay stable and the phone's cache keeps working. Making a batch private takes effect within about a day for people who already had it open; to cut access immediately, the phones re-publish the batch's copies under new keys and the old ones go to the delete queue.
- Public batches use the same path, with long-lived signatures generated for the web share page.

**Uploads**
- A Supabase Edge Function `request-upload` takes the user's session, calls `begin_upload` (checks that the person may add to the batch, using the same rule as `private.can_add_to_collection`, plus their quota), and returns presigned R2 PUT URLs. The phone uploads with a background `URLSession` so uploads finish and resume after the app is suspended.
- On success, `finish_upload` records each object's size, which keeps per-user usage exact.
- Uploads go straight from the phone to R2, so our servers never carry image bytes.

**On the phone**
- Make every tier from one decode of the original (as `ShareCopyMaker` does), not one decode per size.
- Disk cache of about 500 MB (`URLCache` or a small custom cache keyed by photo, version and tier), plus an in-memory cache of decoded images.
- Prefetch the next few rows; load `s` for batch prints first so the desk appears instantly, then upgrade.

**Housekeeping**
- `storage_gc_queue` collects keys from deleted photos, including a contributor's photos the batch owner removes; a scheduled Edge Function (or `pg_cron` calling it) deletes them from R2 after 7 days.
- Deleting an account queues every object under that person's prefix, including copies of photos they added to friends' batches.
- Copies whose upload never finished are dropped after a day (`expire_stale_uploads`), so they stop counting toward the photo limit.

`storage.sql` is a draft written before the camera was set aside and before group batches. It still has RAW-backup tables and re-render dedupe that can be dropped, and it doesn't know about `photos.added_by` yet. It was run once on a local Postgres 16, never on a real Supabase project; update it before using it.

### Why start on Supabase Storage and move later?

It's what the app uses today, it needs nothing extra to run, and at 1k users it costs about the same as R2. Its cached egress ($0.03/GB) is what makes it about 2.5 times the R2 bill at 10k and 3 times at 100k. Because rows store paths (`share_path`) rather than full URLs, moving is a bucket copy, the Worker, and a change to how `SupabaseBackend` signs links. Move before a few thousand active users, so it isn't done under load.

## 8. Pricing model

Shared copies cost about $0.01 per 1,000 photos per month on R2, and a typical active user costs about $0.01 to $0.04 a month all in (section 6). With the camera, looks, editor and RAW backup set aside, there's no expensive feature left to put behind a paywall, so the suggestion is **free now, one optional paid tier later**.

**Launch and TestFlight: free.** No paywall, no ads. A fair-use cap of 10,000 shared photos per person (about $0.12 a month at the cap on R2). Supabase's free plan covers TestFlight; the $25 Pro plan covers the first thousand or so active users.

**Later, once people use it weekly: Batches Plus**, a working name.

| | Free | Batches Plus |
| --- | --- | --- |
| Price | $0 | $1.99/month or $14.99/year |
| Batches, frames, group batches, feed, sharing links | Yes | Yes |
| People who can add to one group batch | Up to 10 | Unlimited |
| Shared photos | 10,000 | 100,000 |
| Full-resolution downloads for viewers | No | Owner turns it on per batch |
| Public web page for a batch, with its own link | No | Yes |

Everything social stays free, because a group batch only works if friends can join and add without paying. Plus is for the person who runs the trips and wants originals and a page to send around. Free group batches are capped at 10 contributors so big events are the natural upgrade, while friend groups never hit it.

**Does it cover costs?** After Apple's 15% (Small Business Program), with 80% of subscribers paying yearly, Plus brings in about $1.19 per subscriber per month.

| | 1k MAU | 10k MAU | 100k MAU |
| --- | --- | --- | --- |
| Monthly cost (section 6, on R2) | about $36 | about $110 | about $880 |
| Subscribers needed to break even | about 30 (3%) | about 92 (0.9%) | about 740 (0.7%) |
| Revenue at 3% paying | about $36 | about $357 | about $3,570 |

At 1k users it roughly breaks even; past a few thousand it pays for itself with room to spare. The 3% is a guess to check against real usage. Raising the price to $2.99 a month or $19.99 a year brings in about 40% more per subscriber. Developer time and the $99 Apple fee aren't counted.

## 9. Decisions only Kevin can make

1. **When to move shared copies from Supabase Storage to R2.** The suggestion: before a few thousand active users, or once Supabase egress passes about $20 a month.
2. **Whether to have a paid tier at all, and when.** Section 8 suggests free at launch and Batches Plus later. Full-res downloads, the part most worth paying for, add about 45% to stored bytes when on for a fifth of photos.
3. **The free photo cap and group size.** 10,000 is a suggestion; even 50,000 costs about $0.60 per person per month at the cap.

Defaults I picked that are easy to change: R2 over B2 or Bunny for one vendor; HEIC over JPEG in the app; signed links through a Worker rather than unguessable URLs alone; 7 days before deleted photos' copies are removed.

## 10. If the camera and editor come back

Kept from the earlier plan so it isn't lost; none of it applies now.

- **RAW stays local.** The camera saves the DNG to Photos as the RAW alternate (`PhotoSaver`); iCloud Photos backs it up at no cost to us.
- **Copies come from RAW plus the edit recipe**, as 10-bit Display P3 HEIC, because film looks band visibly at 8-bit. Recipes live in `photos.edit`.
- **Re-edits make a new set of copies** under new keys, deduped by a hash of source, recipe and pipeline version; old copies go to the delete queue after 7 days. Budget about 20% more uploads.
- **Optional RAW backup** as a paid add-on: encrypted on the phone (CryptoKit, keys wrapped in iCloud Keychain), stored in R2 Infrequent Access ($0.01/GB-month), Wi-Fi and charging only, capped at 250 GB. At 5% of users subscribing it costs about $8, $84 and $840 a month at 1k, 10k and 100k users.
- **A paid tier** could then sell the camera's looks, the full editor and RAW backup, suggested at $3.99 a month or $29.99 a year (VSCO Plus is $29.99 a year; Glass is $39.99).

## 11. What the code will need when R2 goes live

**Supabase**
- Update `supabase/storage.sql` (drop the RAW-backup and re-render parts, add `photos.added_by` to the ownership checks) and add it as the next migration.
- Add the `request-upload` Edge Function and the signing Worker.
- Copy the `media` bucket to R2, then drop it and its policies (`20261101000100_shared_copies_bucket.sql` and the copy policy in `20261103000000_group_piles.sql`).

**Swift**
- `SupabaseBackend.publish`: upload to presigned R2 URLs from `request-upload`, with a background `URLSession`.
- `SupabaseBackend.finish`: build image links from the signed paths `signed_media_paths` returns, instead of Supabase Storage signed URLs.
- `ShareCopyMaker`: add the `x` tier when the viewer needs it.
- `PhotoImage`: choose a tier from the on-screen pixel size, as in section 3 (it already does for `s`, `m`, `l`).

**`README.md`**
- Backend section: R2 for images, Supabase for sign-in and data, and a link to this doc.
