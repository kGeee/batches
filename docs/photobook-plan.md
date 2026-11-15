# Photobook: implementation plan

Turn one or more batches into a printed book that the owner lays out and orders. The screens are in `docs/ui-concepts/photobook.html` (rendered to `book-*.png`). This plan builds it **on the web viewer first** (`web/`, served at batches.space/app), then brings it to iOS.

## Why the web can go first

- **Photos.** The web only ever has shared copies, never originals. The largest, `l`, is 1800 px on the long edge. A photo filling an 8 × 8 in page prints at 1800 / 8 = 225 dpi, which is good enough for a photobook (aim for 200 dpi or more and refuse below 150). So the square book works from shared copies alone. Larger formats and panoramas across a spread need full-size copies, which come later (phase 6).
- **Look.** `web/src/look.js` already ports frames, fonts, backgrounds and freehand boards from the app. The book reuses it, so a chapter looks like its batch.
- **Access.** Row level security already decides which batches and photos someone can see. A book can only use photos its owner can already load.
- **Payment.** A web checkout for a physical product avoids App Store in-app purchase questions entirely.

## Rules carried over from the app

1. **Never cropped.** Every layout is computed from each photo's `pixel_width / pixel_height`. Frames add space around a photo; they never change its shape. The only thing that cuts anything is the printer's trim, and the editor shows the trim and safe area so nothing important sits in it.
2. **Originals never go to the cloud** unless the photo's owner agrees, for one print (phase 6).
3. **The server never touches pixels.** Pages are rendered in the browser (or on the phone) and only the finished PDF is uploaded, for the printer.
4. **One renderer.** The editor, thumbnails, preview and print output all draw from the same book document with the same component, so what you arrange is what prints.

## The book document

A book is one JSON document, versioned and stored in `books.doc`. Positions are fractions of the page width, like `BatchBoard`, so a page draws the same at any size, from a 58 px thumbnail to a 2400 px print render.

```jsonc
{
  "v": 1,
  "format": "square8",                    // see format.js
  "title": "California, fall 2026",
  "byline": "kevin · Theo · Maya",
  "cover": { "photo": "<photo id>", "cloth": "oat", "font": "didot" },
  "chapters": [
    { "id": "c1", "batch": "<collection id>", "title": "Big Sur, one afternoon", "font": "classic", "background": "light", "frame": { "kind": "whiteBorder", "borderWidth": 14 } }
  ],
  "pages": [                              // in reading order; pages[0] is page 1 (a right-hand page)
    {
      "id": "p6", "chapter": "c1", "background": "kraft", "layout": "freehand",
      "items": [
        { "kind": "photo", "photo": "<photo id>", "x": 0.31, "y": 0.43, "w": 0.36, "rotation": -6, "z": 1, "frame": "polaroid" },
        { "kind": "text", "text": "the long way home", "x": 0.32, "y": 0.89, "size": 0.046, "font": "handwritten", "rotation": -4 }
      ]
    }
  ],
  "spans": [                              // items that run across a spread, positioned on the spread
    { "left": "p4", "item": { "kind": "photo", "photo": "<id>", "x": 0.5, "y": 0.44, "w": 0.92 } }
  ]
}
```

- `w` is the print's width including its frame. The height follows from the photo's aspect ratio, so an item can't distort a photo.
- A page's `layout` names the template it came from (`one`, `two`, `stack`, `three`, `grid`, `opener`, `text`, `freehand`). Moving an item by hand turns the page into `freehand`. Choosing a template re-flows the page's photos.
- The document is sanitized on load with the same idea as `sane` in `look.js`: positions clamped, unknown kinds dropped, and photos that are no longer visible (unshared or deleted) drawn as a "Photo no longer available" placeholder and flagged in preflight.

## Data model (one migration)

`supabase/migrations/<ts>_books.sql`:

| Table | Columns | Rules |
| --- | --- | --- |
| `books` | `id`, `owner_id`, `title`, `format`, `doc jsonb`, `revision int`, `status` (`draft`, `ordered`), `created_at`, `updated_at` | Only the owner reads and writes. `doc` size capped (about 512 KB) with a check. |
| `book_batches` | `book_id`, `collection_id`, `position` | Kept in step with `doc.chapters` by the client. Lets queries find books that use a batch, and gives later features (permission requests, "your batch is in Kevin's book") something to join on. Insert allowed only for batches the owner can view (`private.can_view_collection`). |
| `book_orders` | `id`, `book_id`, `user_id`, `quantity`, `status`, `pdf_path`, `vendor`, `vendor_ref`, `amount_cents`, `currency`, `created_at` | Owner reads own orders. Status changes only by the order Edge Function (service role). |

Plus a private `prints` storage bucket for finished PDFs, writable only into `{user}/{book}/…`, readable by the owner and the service role.

Saving uses the revision for optimistic concurrency: `update books set doc = $1, revision = revision + 1 where id = $2 and revision = $3`. If no row is updated, another tab saved first, and the editor asks which version to keep.

pgTAP: `supabase/tests/database/books.test.sql` covers owner-only access, `book_batches` refused for batches you can't see, other people unable to read a book or its PDF, and blocked users following the existing rules.

## Code layout (web)

```
web/src/book/
  format.js       trim size, bleed (3 mm), safe margin (6 mm), page-count rules, price table
  doc.js          create from batches, sanitize, migrate older versions, chapter helpers
  layout.js       auto layout and page templates from photo shapes (pure functions)
  preflight.js    effective dpi per placed photo, items in the bleed or past the safe line, missing photos
  history.js      undo and redo over document edits (a reducer of patches)
  render.jsx      <Page>, <Spread>, <SpreadThumb>; container-query units, as in the mockup
  NewBook.jsx     desk selection mode and the New book sheet
  Editor.jsx      spread view, selection tools, page strip, chapter tabs
  Tray.jsx        photos by batch, ticks for photos already used, drag source
  PageEdit.jsx    one page large: freehand handles, layout picker, page background, frame
  Pages.jsx       all pages by chapter, reorder spreads and chapters
  Cover.jsx       cover photo, cloth, title font
  Order.jsx       preflight summary, quantity, price, checkout
  pdf.js          renders pages to canvases at 300 dpi and assembles the PDF (pdf-lib)
  *.test.js       vitest for format, doc, layout, preflight, history
```

Changes outside `book/`:

- `api.js`: `books(me)`, `book(id)`, `createBook(doc, batchIDs)`, `saveBook(id, doc, revision)`, `deleteBook(id)`, `uploadBookPDF(...)`, `startCheckout(bookID, quantity)`.
- `ui.jsx` `parseRoute`: `/app/books`, `/app/books/new`, `/app/books/<id>`, `/app/books/<id>/pages`, `/app/books/<id>/cover`, `/app/books/<id>/order`.
- `vite.config.js` `likeVercel`: add `books(/…)?` to the `/app` rewrite pattern. `site/vercel.json` already rewrites every `/app/*` path.
- `App.jsx`: a Books tab, and a "Make a book" button on the desk.
- `photos.js`: a `printSource(photo)` that returns the largest copy (`l`, later the full-size copy) as a decoded bitmap for the PDF renderer. HEIC decode already runs in the worker for browsers without HEIC support.
- `package.json`: add `vitest` (dev) and `pdf-lib`. Choose a drag library in phase 2 (plain pointer events, or `@dnd-kit/core` for the tray and page reordering).

## Phases

Each phase ends with something usable at batches.space/app, behind a `?books=1` flag until phase 5.

### Phase 0: foundations

- `format.js` with the square 8 × 8 in hardcover only (the format the web can print well). Its trim, bleed and safe sizes, and page counts from 20 up in steps of 2.
- `doc.js`: shape, `createFromBatches(batches, { order: 'chapters' | 'date' })`, `sanitize`, version field.
- The migration, RLS, the `prints` bucket and the pgTAP tests above. Run `supabase db push` and `supabase/tests/run-linked.sh`.
- `api.js` book functions, and vitest wired into `npm test`.

**Done when** `npm test`, `npm run build` and the pgTAP run pass, and a book row can be created and read back only by its owner.

### Phase 1: make a book and see it

- **Auto layout (`layout.js`).** For each chapter: an opener page (title in the batch's font, date, place, contributors), then photos packed in order onto pages. Templates are chosen from aspect ratios: one large, two side by side (portraits), stacked (landscapes), three, a grid of four, and a panorama across a spread when one would otherwise print under 200 dpi or tiny. Each template is solved inside the safe area so every photo is whole and at least about 40% of the page wide where possible. Then a title page and an even page count.
- **Desk selection** (`NewBook.jsx`). "Make a book" turns desk tiles and "Shared with you" batches into numbered choices, as in screen 1. Then the New book sheet: title, size (one choice for now, the others shown as "coming"), batch order, *By batch* or *By date*, *Keep each batch's look*.
- **Renderer** (`render.jsx`). `<Page>` and `<Spread>` draw from the document with the existing `Framed` and `Photo` components, gutter shading and folios included.
- **Read-only book page** at `/app/books/<id>`: spreads one after another, plus a Books list.

**Done when** someone can pick three batches (one of them a friend's), get a laid-out 20-page book saved as a draft, and reopen it.

### Phase 2: the editor

- Spread view with chapter tabs and the page strip (screen 3).
- Selecting a photo: Swap, Frame, Caption, Remove.
- The photo tray: tabs by batch, ticks for used photos, "Not in book" badges. Drag onto a page to add, or onto a photo to swap.
- One page large (screen 4). Freehand move, resize and rotate with handles, inside the page and clamped like `BatchBoard.clamped`. The layout picker offers only templates that fit the page's photos uncropped. Page background (paper, linen, kraft, dark, custom, or the whole chapter). Frame from the batch, or per page.
- Text items: captions, chapter titles, free text, in the batch fonts.
- Undo and redo, autosave after a short pause with the revision check, and a "Saved" indicator.
- Keyboard: arrows nudge, Delete removes, Cmd-Z and Shift-Cmd-Z.

**Done when** every interaction in screens 3 and 4 works with mouse, touch and keyboard, and reloading shows exactly what was there.

### Phase 3: pages and cover

- All pages by chapter (screen 5): drag spreads within and between chapters, drag a chapter header to move the whole batch, add or remove pages (kept even, at least 20), and *Re-lay out* a chapter.
- Cover (screen 6): any photo from any chapter, cloth colour, title font, byline, and a spine preview once page counts make the spine wide enough.
- Credits: "Photo by …" on pages of photos added by someone else, and "Photos by …" on a friend's chapter opener, with a switch to hide them.

### Phase 4: print output

- **Preflight** (`preflight.js`). Effective dpi = source pixels ÷ printed inches for every placed photo. Warn under 200 and block under 150. It also checks for text or important items past the safe line, missing photos and an odd page count. Problems are listed on the order screen and jump to the page.
- **PDF** (`pdf.js`). Each page goes to an offscreen canvas at 300 dpi plus bleed (8.25 × 8.25 in, or 2475 px) and is saved as high-quality JPEG. pdf-lib assembles the interior PDF and a separate cover PDF at the printer's sizes. The canvas renderer and `<Page>` share one geometry function so they can't drift apart. Visual regression check: render a fixture book both ways and compare.
- **Fonts.** Didot, Futura, Noteworthy and American Typewriter are Apple-only, so a Windows or Android browser would print a fallback. For print, bundle open-licensed stand-ins as webfonts used by both the screen and the PDF (for example Playfair Display, Jost, Caveat and Courier Prime). Then a book prints the same from any computer. This is decision 2 below.
- Upload the PDFs to `prints/{user}/{book}/{revision}/` and show a page-by-page preview of the actual PDF.

**Done when** a book's PDF passes the chosen printer's file checker and a test copy is printed by hand.

### Phase 5: ordering

- **5a, by hand first** (as `docs/money.html` suggests): Order records a `book_orders` row with the PDFs and takes payment with Stripe Checkout from a Supabase Edge Function. Kevin uploads to the printer manually. This shows demand before building a printer integration.
- **5b, printer API**: an Edge Function quotes price and shipping, submits the print job with the PDF links, and takes the printer's status webhooks into `book_orders.status`, with emails at "ordered", "shipped" and "delivered". Candidates: Lulu Print API, Gelato or Prodigi (decision 3).
- Contributors can order their own copy of a book they appear in, once the owner allows it.

### Phase 6: iOS and full-size copies

- The same document format in Swift (`Codable`, sanitized the same way). The renderer is ported to SwiftUI, reusing `PhotoFrame` and `BatchFont`, and the editor follows screens 3 and 4.
- **Full-size print copies.** When a book needs more than the shared copy (larger formats, panoramas across a spread), the photo's adder gets a request in the app: "Kevin wants to print 3 of your photos." Approving uploads a full-size `x` copy (the tier `docs/storage-plan.md` already describes) to a location only the book's owner and the printer can read. Until then, preflight shows the photo as waiting.
- Then add the landscape lay-flat and zine formats.

## Testing

- **Unit (vitest):** layout never crops (every placed photo's height equals `w / aspect` plus its frame), everything stays inside the safe area, page counts stay even, sanitize clamps hostile input, history undo and redo round-trip, and dpi maths.
- **Database (pgTAP):** `books.test.sql` as above.
- **Browser:** a seeded test account with three batches, plus one shared from a second account. Go through the whole flow in the browser for each phase. Check Safari (native HEIC) and Chrome (worker decode).
- **Print:** each PDF change is checked against the printer's preflight tool, and one physical proof is ordered before launch.

## Decisions needed

1. **Friends' photos without asking.** Can a book use photos from a batch shared with you, at shared-copy resolution, without the friend's approval (they're credited), or does every friend's photo need a yes first? The plan assumes no approval for shared copies and approval for full-size copies.
2. **Fonts.** Bundle open stand-ins for print so books look the same everywhere (recommended), or print Apple faces only from Apple devices.
3. **Printer.** Lulu, Gelato or Prodigi for hardcover 8 × 8, based on price, quality and shipping regions. Decide after printing a proof with each.
4. **Price.** $39 is a placeholder; set it once the printer cost is known, aiming for at least a 30% margin.
5. **Group editing.** One owner per book in v1. Co-editing (Theo arranging his chapter) would need presence and merging, so it's left out.
