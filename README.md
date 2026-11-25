# Batches

A social photo app for iPhone, with a web companion at [batches.space](https://batches.space). Version 1.0, build 11, on TestFlight.

1. **Your desk.** Every album, day trip or shoot is a batch: a loose pile of prints on your desk with a cover you choose on top. Tap it and the prints fly out into a scrolling gallery with the frame style, font, background and arrangement the owner picked.
2. **Full frame, always.** Every photo is shown whole at its own shape. Nothing is cropped to a square or 4:5.
3. **Sharing with the people who were there.** A batch is private until you share it with specific people, your followers, or everyone on Batches. Friends can like and comment on single photos, and you can let them add their own photos to a batch.
4. **On the web.** `batches.space/b/<id>` links open in the app, or in a web viewer that shows the same batch the same way. The web viewer can also lay batches out as a printed photobook.

There is also an editing workspace and a RAW camera with its own color pipeline. The editor is in the app and in a Photos extension. **The camera (the Shoot tab) is switched off for now**: the code is all here, and `SignedInTabs.showsShoot` in `Strewn/App/RootView.swift` brings it back.

**About the name.** The app started as Strewn. The app, targets and scheme are now Batches, but folders (`Strewn/`), bundle ids (`com.kevingeorge.strewn*`, which App Store Connect is tied to) and the `strewn://` URL scheme keep the first name. In the code and the database a batch is still a pile or a collection (`PhotoCollection`, `collections`); in everything people read it is a batch.

## Native iOS

The app runs on Apple's own frameworks, with no web views:

| Area | Frameworks |
| --- | --- |
| UI, transitions, haptics | SwiftUI (`matchedGeometryEffect`, `Layout`, `scrollTargetBehavior`, `sensoryFeedback`, context menus) |
| Library | PhotosUI `PhotosPicker` to start and add to batches; PhotoKit for suggested batches in New batch (`Strewn/Services/SmartBatches.swift`) and to write edits back as revertible Photos edits (`PHContentEditingOutput` with the recipe as adjustment data) |
| Develop and edit | Core Image (`CIRAWFilter`, built-in filters, custom Metal CI kernels), MetalKit preview |
| Photos extension | "Edit with Batches" inside the Photos app (`PHContentEditingController`), sharing the same editor and pipeline |
| Sharing | LinkPresentation: a `batches.space` link with the batch's title and a photo attached, so Messages shows a preview without fetching anything |
| Posting to Instagram and TikTok | Core Graphics and Core Image render 4:5, 1:1 and 9:16 posts on this phone; AVFoundation (`AVAssetWriter`, H.264) makes a slideshow video; the system share sheet hands them off |
| Links | Universal links (`applinks:batches.space`) and the `strewn://` scheme |
| Copy/paste edits | `UIPasteboard` with a custom type, so a copied recipe survives between sessions |
| Capture (switched off) | AVFoundation: `AVCapturePhotoOutput` with Bayer RAW and Apple ProRAW, manual ISO, shutter and white balance; `onCameraCaptureEvent` (AVKit, iOS 18) for Camera Control and the volume buttons |

## Suggested batches

New batch suggests days and trips from the camera roll, each shown as a small pile. They come from `SmartBatchGrouping` in `Strewn/Services/SmartBatches.swift`, run on the phone over the last 12 months of the library:

- Photos more than 90 minutes apart start a new moment; moments under 6 hours and 25 km apart join into a day; days more than 80 km from home (the busiest ~1 km grid cell) join into a trip.
- Screenshots, hidden photos, shared-album photos and photos already in one of your batches are left out, and a burst counts once.
- A suggestion needs at least 6 photos. The review grid picks the first 60 (the batch limit) and you tap to change them.
- The place name comes from reverse geocoding the suggestion's centre and fills the batch's place, which you can edit. Photo locations never leave the phone.

Suggestions need full or limited library access, asked for only from the card in New batch. Without it the card goes away and the system picker works as before. Onboarding and "add photos" still use the system picker. Grouping photos that were imported together (film scans, AirDrops) isn't built yet: PhotoKit has no public date-added field, so it needs a test on a real library first.

## Core rule: full frame, never cropped

Instagram-style square and 4:5 crops are the thing this app exists to avoid. Every view shows the whole photo at its native aspect ratio.

- `Photo` stores `pixelWidth` and `pixelHeight`, so layout knows each photo's shape before the image loads.
- `PhotoImage` is the only view that draws a photo. It uses `.aspectRatio(photo.aspectRatio, contentMode: .fit)` and never `.fill` or `scaledToFill`. Don't add another image view; reuse this one.
- In the single-column gallery each photo is capped to the visible height minus its frame, so a tall portrait is shown whole on one screen instead of running off the bottom. Width follows from the aspect ratio.
- The two-column layout is a masonry `Layout` (`MasonryLayout`), so photos keep their own heights instead of being cut to equal tiles.
- Frames only add space around a photo (`FrameStyle.insets`); they never change its shape.
- Desk-pile prints keep their true proportions too (panoramas are wide prints, portraits narrow).
- The full-screen viewer is letterboxed on black, and the camera preview shows the full 4:3 sensor frame.
- The film roll keeps each frame's own width at a shared height, so nothing is trimmed to fit a fixed film gate.
- The editor's crop is opt-in. "Original" is the default and keeps the whole frame; the gallery and viewer label a photo as cropped only when its owner chose a crop.
- The web viewer and the photobook follow the same rule: every layout is computed from each photo's own shape.
- Posts made for Instagram and TikTok (`SocialShareSheet`, `SocialExport`) keep the whole photo on a blurred copy of itself or on the batch's background. Cropping to fill the post is a choice the person makes in that sheet, never the default.

## Getting started

### The iPhone app

Requirements: Xcode 16 and iOS 17 or later.

```sh
brew install xcodegen
xcodegen generate
open Batches.xcodeproj
```

`Batches.xcodeproj` is generated from `project.yml` and is not in git, so change settings, the version and the build number there. Bump `CURRENT_PROJECT_VERSION` for every TestFlight upload. `docs/external-testflight.md` covers getting a build to outside testers.

The app runs on the `MockBackend` with sample data until real values are configured (demo mode). In demo mode, sign in with any email and any six-digit code; you become `@kevin` with three sample friends. The sample photos point at picsum.photos placeholders at a mix of aspect ratios, and demo data resets on relaunch. To use the real backend, see "Run it against Supabase" below.

### The web viewer

```sh
npm --prefix web install
npm --prefix web run dev      # http://localhost:5173, strict port
npm --prefix web test         # vitest, the photobook's layout and print checks
npm --prefix web run build    # writes straight into site/app/
```

It needs `web/.env.local` (gitignored) with the same project and publishable key as the app:

```
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=sb_publishable_...
VITE_GOOGLE_CLIENT_ID=<client-id>.apps.googleusercontent.com   # optional: Google Photos Picker import
```

The dev server answers `/b/<id>` and `/app/...` the way Vercel does in production (see `web/vite.config.js`). The built viewer in `site/app/` is committed, so rebuild it before deploying.

### The site

`site/` is plain HTML deployed to Vercel: the landing page, privacy policy, support page, the built web viewer under `app/`, and `.well-known/apple-app-site-association`. The Vercel project's Root Directory is `site`, so pushes to `main` deploy it through the GitHub integration; to deploy by hand, run `vercel deploy --prod` from the repo root (`.vercelignore` uploads only `site/`). Rebuild `site/app` (`npm --prefix web run build`) and commit it first: Vercel serves the committed build, it doesn't build the viewer. `site/vercel.json` sends `/b/<id>` and `/app/...` to the viewer and redirects `www` to the bare domain.

## Layout

```
.
├── project.yml                     XcodeGen spec: app + Photos editing extension, supabase-swift, Metal CI kernel flags, version and build
├── Extensions/PhotoEdit/           PHContentEditingController hosting the same EditorView
├── Strewn/                         The iPhone app
│   ├── App/                        App entry, RootView (floating tab bar), AppModel (@Observable), Theme, PaperUI (the app's own sheets
│   │                               and controls), WindowLayout (wide windows), DuoPreview (debug-only stand-in for a folding iPhone)
│   ├── Models/                     User, PhotoCollection, Photo, FrameStyle, BatchLook (font, board, background), DeskLayout, EditRecipe, SampleData
│   ├── Features/
│   │   ├── Account/                SignInView, CreateProfileView, FirstBatchOnboardingView
│   │   ├── Desk/                   Your desk: profile header and your batches, in a grid, sideways or freehand
│   │   ├── DeskPile/               DeskPileView, PileLayout, FilmRollPileView (canister + curled strip)
│   │   ├── Gallery/                GalleryView, FilmRollView, PhotoImage, PhotoFrame, FramePickerSheet, BatchFontSheet, BoardEditorView,
│   │   │                           PhotoCommentsSheet, FullFrameViewer, PullDownToDismiss
│   │   ├── Editor/                 EditorView (workspace UI), EditorModel (recipe, undo, compare, copy/paste, preview)
│   │   ├── NewPile/                NewPileSheet (PhotosPicker import)
│   │   ├── Friends/                Friends' batches feed
│   │   ├── People/                 FindPeopleView, ProfileView, FollowListView, AvatarView
│   │   ├── Share/                  SharePileSheet (who can see and who can add), LinkShareButton (link with a preview)
│   │   ├── Safety/                 Report, block, blocked list, delete account
│   │   └── Camera/                 CameraScreen, CameraModel, PreviewRenderer (switched off)
│   ├── Editing/                    EditRenderer (recipe → image), MetalImageView, PhotosEditSaver
│   ├── Camera/                     CameraController, PhotoSaver, PreviewCalibrator
│   │   └── ColorPipeline/          ColorPipeline, FilmLook, ToneCurve, CubeLUT, DeviceProfile, StrewnKernels.ci.metal
│   ├── Services/                   Backend protocol + MockBackend, SupabaseBackend, LocalLibrary (originals on the phone),
│   │                               ShareCopyMaker (HEIC copies), PhotoLinks (signed links)
│   └── Resources/                  Info.plist, Config.xcconfig, Strewn.entitlements, PrivacyInfo.xcprivacy, Assets.xcassets, Looks/*.cube
├── supabase/
│   ├── config.toml                 Supabase CLI config (auth: six-digit email codes, redirect URLs)
│   ├── migrations/                 Nine migrations, listed under "Run it against Supabase"
│   ├── templates/                  Sign-in email templates
│   ├── tests/database/             pgTAP tests of who can read and write what
│   ├── tests/run-linked.sh         Runs them against the linked project without Docker
│   └── storage.sql                 The R2 storage plan's tables and functions (draft, not a migration yet)
├── web/                            React + Vite web viewer
│   └── src/                        App, Batch, api (supabase-js), photos (signed links, cache), look (frames, fonts, boards ported
│                                   from the app), heic.worker (HEIC → JPEG), book/ (photobooks)
├── site/                           batches.space: landing, privacy, support, vercel.json, the built viewer in app/
├── marketing/app-store/            App Store screenshots at every accepted iPhone size, and promo art
├── tools/                          Python scripts that compose the screenshots, App Store art and site images
└── docs/                           color-pipeline, storage-plan, external-testflight, photobook-plan, monetization drafts (money*.html),
                                    ui-concepts/ (screen and photobook mockups), duo-preview/ (wide-window screenshots)
```

`PhotoCollection` is named that way so it doesn't collide with Swift's `Collection` protocol.

## How the pile spreads into the gallery

- Each print in `DeskPileView` has `matchedGeometryEffect(id: photo.id, in: namespace)`. The matching photo in `GalleryView` uses the same id, so SwiftUI moves and resizes it from the pile to its gallery slot.
- Prints are placed with `.position` (not `.offset`) so the matched frame is where the print really is. Rotation is applied after the matched effect, and the gallery photo carries a `pileRotation(angle)` transition that turns it from its pile angle to upright, and back on close.
- `PileLayout` derives each print's angle, offset and width from the photo's UUID, so a pile looks the same everywhere and only reshuffles when the cover changes.
- While a pile is open its grid slot is kept as an empty square so the desk doesn't reflow.
- The gallery uses `LazyVStack`; photos far off screen just fade. For very large piles, limit the hero animation to the photos in the pile stack, which the code already does.
- **Closing.** The back button, or pull down to put the pile back. `pullDownToDismiss` (Gallery/PullDownToDismiss.swift) reads the scroll view's overscroll with `onScrollGeometryChange` and the moment the finger lifts with `onScrollPhaseChange`. Only a pull that starts while already at the top counts, so it never fights scrolling down the gallery or the film roll, or the bounce at the end of a fling. As you pull, the photos shrink toward the desk (a render-only `scaleEffect`) and the wall fades; past 90 pt there is a light haptic tick, and letting go there sends the photos back onto the pile with the same matched-geometry animation. Letting go earlier springs back. Dragging the header down does the same from any scroll position, and VoiceOver's escape gesture closes too. Reading the scroll needs iOS 18, so on iOS 17 only the header drag and the back button close a pile.

## How a batch looks

The owner decides how everyone sees a batch, and all of it is stored with the batch:

- **Frame** (`FrameStyle`: kind, border width, layout, stored as JSON in `collections.frame`): none, white border, thin black, Polaroid, film strip or gallery mat, in one column or two. The `.photoFrame(_:caption:frameNumber:)` modifier draws each style: Polaroid uses the photo caption in the bottom margin, film strip draws perforations and edge numbers with `Canvas`.
- **Font** (`BatchFont`): Classic, Modern, Rounded, Typewriter, Didot, Futura or Handwritten. Every face ships with iOS, so nothing is downloaded.
- **Background** (`BatchBackground`): light, dark, desk or kraft.
- **Board** (`BatchBoard`, edited in `BoardEditorView`): a freehand arrangement where the owner places, sizes and turns each photo. Positions are fractions of the width, so it draws the same on any screen.
- **Description**: a short line under the title.
- **Cover**: owners get a star on each photo to set it. Viewers get none of these controls.

Font, board, background and description are their own columns rather than part of the frame JSON, because older builds fail to decode a frame with values they don't know. Adding a font or background means widening the check on its column too.

**Your desk** has its own arrangement (`DeskLayout`): grid, sideways or freehand, with groups and optional tilted piles. It is yours alone; friends see your batches in a plain grid on your profile.

Owners can add photos, remove them and reorder them after a batch is made.

## Film roll batches

Choosing the film strip frame turns the whole batch into film:

- **Collapsed:** `FilmRollPileView` draws a 35mm canister with the cover pulled out first and the next frames chained end to end, curling under (`FilmRollLayout` walks along the strip, turning each frame by its bend). Frames keep their true widths, so a panorama is a long frame.
- **Expanded:** `FilmRollView` is one continuous roll on a single black film base, with frames separated only by film base and edge numbers printed on the film. It has two directions, set by `FrameStyle.rollDirection` and switchable with the Down / Sideways control at the top:
  - **Down (default).** A vertical `LazyVStack` you scroll with your thumb like any feed. Perforations run down both sides (`SprocketHoles(axis: .vertical)`), so every frame gets nearly the full screen width, and the meta row and Edit/cover buttons sit under each frame. Frames are capped so a tall portrait still fits on screen whole.
  - **Sideways.** A horizontal `ScrollView` with perforations along the top and bottom and `.viewAligned` snapping frame by frame. The meta row follows the centered frame. Strip height is the tallest that still shows a 3:2 frame whole, so turning the phone sideways gives a bigger strip.
- The same `matchedGeometryEffect` ids connect the strip in the pile to the roll in either direction, with each frame unrotating from its curl angle.

## Wide windows

`WindowLayout` is decided once at the root from the size class, never from the device or its orientation, and screens read it instead of `horizontalSizeClass`. In a regular-width window grids go from two columns to three and the tab bar adapts. `DuoPreview` is a debug-only stand-in for a folding iPhone: launch on an iPad simulator with `-duoPreview outer`, `inner` or `innerLandscape` (see the comment at the top of the file). `docs/duo-preview/` has screenshots.

## Editing workspace

`EditRecipe` is the whole edit: look and strength, exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, grain, vignette, fade, aspect and straighten. It is stored on the `Photo` (and in the backend as JSON), never baked into the original.

- **Source.** `Photo.editSourceURL` is the DNG for photos shot with the app's camera, otherwise the untouched original file. For RAW, exposure and white balance go back into `CIRAWFilter`, so editing is a true re-develop from sensor data.
- **Render order** (`EditRenderer`): RAW develop or decode → look (blended by strength against Neutral) → highlights/shadows → 5-point tone curve (contrast, whites, blacks, fade) → vibrance and saturation → vignette → grain → straighten → crop to the chosen aspect.
- **Live preview.** Renders off the main thread at 1600 px on the long side, in RAW draft mode while a slider is moving, shown through `MetalImageView` (aspect fit).
- **Workspace.** Looks, Light, Color, Effects and Crop tools; a dot on each changed adjustment; undo and redo per gesture; press and hold the photo to compare with the original; Reset per slider; Revert to original.
- **Copy and paste.** Copy puts the recipe on the system pasteboard. Paste, or pasting to the whole batch, applies everything except each photo's own crop.
- **Saving.** Done renders a full-resolution 10-bit HEIF next to the original. When the photo is also in the Photos library, the edit is written there as a revertible edit with the recipe as adjustment data, so Photos shows "Edited", can Revert, and the app can reopen it with the sliders where they were.
- **In the Photos app.** The `BatchesPhotoEdit` extension hosts the same `EditorView`, so any library photo can be edited with the app's looks. Photos provides Cancel and Done there. Extensions have a tight memory limit, so full-resolution RAW renders there may need tiling or a lower scale factor; check on device.

## Camera and color pipeline (switched off)

The Shoot tab is hidden (`showsShoot = false`), so nothing below runs in the shipping build except the parts the editor shares. `docs/color-pipeline.md` has the detail.

**Capture.** `CameraController` uses a physical `.builtInWideAngleCamera` because Bayer RAW is not available on the virtual dual/triple camera; lens switching swaps physical devices.

| Mode | What you get | Apple processing |
| --- | --- | --- |
| Bayer RAW (default) | One unprocessed sensor readout as DNG | None |
| Apple ProRAW | Apple's multi-frame merge as linear DNG | Merge and noise reduction yes, tone mapping skipped at develop |
| HEIF | Apple's finished image | Full; our look is applied on top |

**Develop.** `ColorPipeline.develop(dng:settings:)`:

1. `CIRAWFilter` demosaics into a scene-linear wide gamut with `boostAmount = 0`, `boostShadowAmount = 0`, `localToneMapAmount = 0`, gamut mapping off, and extended dynamic range kept. White balance comes from the WB dial through `neutralTemperature`.
2. A grade kernel (`StrewnKernels.ci.metal`): warmth, saturation, monochrome in linear light.
3. Optional creative 3D LUT per look: log encode → `CIColorCube` → log decode. Drop `.cube` files in `Resources/Looks` (see the README there for the expected encoding).
4. A filmic kernel: S-curve through middle grey with a toe and a highlight shoulder, so highlights roll off like film instead of clipping.
5. Soft-light grain, then a 10-bit HEIF in Display P3. The DNG is saved alongside as the RAW alternate so the look can be changed later.

The live preview runs the same grade and LUT on video frames. Those frames have already been through Apple's video pipeline, so the preview is a close guide and the saved photo, developed from RAW, is the real result.

Looks: Neutral, Warm 160, Slide 50, Tungsten 800, Mono 400, Faded. The parameters are first guesses to tune on device.

## Accounts and sharing

- **Sign-in & onboarding**: an emailed six-digit code or link (Supabase Auth), or Sign in with Apple. The first sign-in asks for a name and a unique @handle, checked as you type, then guides each new person through making and uploading their first batch (`FirstBatchOnboardingView`) so they land on a desk with a batch already on it. A password sign-in exists only for the App Review account, behind "Sign in with a password".
- **Profiles and following**: find people by name or handle, open their profile, follow or unfollow, and see follower and following lists. Follows are open (no requests), like Instagram's public accounts.
- **Who can see a batch**: every batch starts as **Only me**. Share sets it to **Specific people** (only the people you add), **Followers** (your followers plus anyone you add), or **Anyone on Batches** (anyone signed in). The rule lives in the database (`private.can_view_collection`, in `supabase/migrations/`), so the app can't show a batch to the wrong person even if the app has a bug. `MockBackend` follows the same rule, so demo mode behaves the same way.
- **Group batches**: the owner can let some of the people a batch is shared with add their own photos (`collection_members.can_add`). Each photo records who added it (`photos.added_by`). A contributor edits and removes only their own photos; title, cover, look and sharing stay the owner's.
- **Friends feed**: batches from people you follow, plus batches shared with you directly.
- **Likes and comments** on single photos (`PhotoCommentsSheet`), visible to whoever can see the photo. **Activity** shows what people did to your photos, with a count of what's new on the tab bar.
- **Safety**: report a batch, photo or person; block (both ways: neither person sees the other's batches or added photos, and follows and shares between them go); delete your account. These are what App Review asks for in guidelines 1.2 and 5.1.1(v). Reports land in the `reports` table; see `docs/external-testflight.md` for handling them.

### Links

The share sheet sends `https://batches.space/b/<id>`, or `...?photo=<id>` for one photo.

- **With the app installed**, iOS opens the link in the app (`applinks:batches.space` in `Strewn.entitlements`, matched by `site/.well-known/apple-app-site-association`). `AppModel.open` turns it into the older `strewn://pile/<id>` form, which still works, and opens the batch for anyone who can already see it.
- **Without the app**, the link opens the web viewer, which asks you to sign in and then applies the same visibility rule.
- **The preview in Messages** comes from the phone that sent it: `LinkShareButton` attaches the batch's title and a photo to the share. The page behind the link stays generic, so a private batch still gets a real preview without the server showing anything.
- `strewn://auth-callback` finishes email sign-in (below).

### Shared copies

When a batch is shared, the phone makes three HEIC copies of each photo (320, 800 and 1800 px on the long edge, no location or other metadata; `ShareCopyMaker`) and uploads them. RAW files and originals never leave the phone; `LocalLibrary` remembers where they are, and the server only knows the shared copies' path. Edits to a shared photo upload fresh copies. In a group batch each person uploads the copies of the photos they added, into their own folder.

Copies go to the private `media` bucket in Supabase Storage at `{owner}/{photo}/{revision}/{s|m|l}.heic`. Storage rules let you write only your own folder and read copies only of batches you can see. Viewers get signed links that last six hours. `PhotoLinks` asks for links only for photos about to be shown, in groups of 50, and reuses them until they near expiry; downloaded copies are kept on disk. The web viewer does the same in `web/src/photos.js`, keeping copies in the browser's Cache Storage until sign-out.

`docs/storage-plan.md` describes the longer-term setup (Cloudflare R2 behind a CDN, more sizes, cheaper at scale). Moving to it only changes `publish` and how `SupabaseBackend` signs links. `supabase/storage.sql` is the draft schema for it and stays a draft until then; `supabase/tests/supabase-stubs.sql` lets you try the migrations plus that draft on a plain Postgres.

## Web viewer

`web/` is a React + Vite app served at `batches.space/app`, talking to the same Supabase project with the publishable key. Row level security decides what each signed-in person can read and write, exactly as it does for the iPhone app.

| Address | What it shows |
| --- | --- |
| `/b/<id>`, `/b/<id>?photo=<id>` | A batch, or one photo in it (the links the app shares) |
| `/app` | Your desk |
| `/app/friends` | Friends' batches |
| `/app/people` | Find people |
| `/app/u/<handle>` | Someone's profile |
| `/app/books`, `/app/books/new`, `/app/books/<id>` | Photobooks |

- **Sign-in** is the same emailed code or link, returning to the page you asked from.
- **Look.** `web/src/look.js` ports frames, fonts, backgrounds, boards and the pile layout from the Swift code, so a batch reads the same on the web. Change both when one changes.
- **HEIC.** Safari shows shared copies directly. For Chrome and Firefox, `heic.worker.js` decodes them with `libheif-js` off the main thread, loaded only when first needed.
- **Uploading from the web & Google Photos.** You can create batches and add photos to existing or group batches right on the web — from local files (JPEG, PNG, WebP, HEIC, drag-and-drop) or imported directly via the **Google Photos Picker API** (`web/src/googlePhotos.js`, scope `photospicker.mediaitems.readonly`, enabled when `VITE_GOOGLE_CLIENT_ID` is set). Camera EXIF and capture dates are read in the browser before `<canvas>` builds the `s`/`m`/`l` JPEG shared copies with location stripped.

### Photobooks

The web viewer can lay one or more batches out as a printed book (`web/src/book/`, plan in `docs/photobook-plan.md`). It is on the web first and comes to iOS later.

- A book is one versioned JSON document (`books.doc`) that names photo ids. It can use any photo its owner can see; the photos stay behind the existing visibility rules.
- One renderer draws the editor, thumbnails, preview and print output from that document, so what you arrange is what prints. Pages are never cropped: layouts come from each photo's shape, and the editor shows the trim and safe area.
- Print files are PDFs made in the browser with `pdf-lib` from shared copies and uploaded to the private `prints` bucket in the maker's own folder. The server never touches pixels. `preflight.js` checks resolution before printing.
- **Not done yet:** payment and a printer. An order is recorded with its print files, and its status moves on only from the dashboard or a service-role function.

## Run it against Supabase

The live project is **strewn** (ref `exogbxkigwptelpbdaib`, us-west-1). The app uses `SupabaseBackend` whenever real values are configured, and `MockBackend` (demo mode) otherwise. `SupabaseBackend` sits behind the small `Backend` protocol, so swapping the backend later touches one file.

**Point the app at it.** Real keys never go in `Config.xcconfig`, which keeps placeholders and is safe to commit. Create `Strewn/Resources/Config.local.xcconfig` (gitignored); `Config.xcconfig` includes it:

```
SUPABASE_URL = https:/$()/exogbxkigwptelpbdaib.supabase.co
SUPABASE_ANON_KEY = sb_publishable_...
SUPPORT_EMAIL = you@example.com
PRIVACY_POLICY_URL = https:/$()/batches.space/privacy
```

The `$()` stops xcconfig from treating `//` as a comment. Use the project's **publishable** key (Project Settings, API Keys), or the legacy anon key. Never the secret or service_role key. `SUPPORT_EMAIL` and `PRIVACY_POLICY_URL` show as rows in the account sheet; leave them out to hide the rows. Then build and run. Sign out of demo mode first if you were in it.

**Database changes** go through the Supabase CLI (`brew install supabase/tap/supabase`, then `supabase login`):

```bash
supabase link --project-ref exogbxkigwptelpbdaib
supabase migration new <name>      # write SQL in the new supabase/migrations file
supabase db push                   # apply new migrations to the linked project
supabase/tests/run-linked.sh       # every pgTAP test against it, rolled back, no Docker
```

With Docker running you can use `supabase start` and `supabase test db` for a local stack instead. `supabase test db --linked` also needs Docker (for pg_prove), which is why `run-linked.sh` exists. Pass it test files to run only those. Each test creates its own people, batches and photos, checks what each person can read and write, and rolls everything back.

Keep migrations additive. Builds already on people's phones read `collections` with `*` and ignore columns they don't know, but fail to decode a known JSON column with a value they don't know. That is why new look settings get their own columns. `collections` also has column-level grants, so a new column isn't writable until it is listed.

What the migrations set up:

1. `20261101000000_social_schema.sql`: profiles, follows, batches (`collections`), `collection_members`, photos, count triggers, and the row level security behind the four visibility levels. Signed-out requests read nothing.
2. `20261101000100_shared_copies_bucket.sql`: the private `media` bucket (HEIC only, 5 MB) and its policies.
3. `20261101000200_tighten_functions_and_policies.sql`: changes from the database advisors. `can_view_collection` moves to an unexposed `private` schema, trigger functions can't be called over RPC, owner policies are split by action, and missing foreign-key indexes are added.
4. `20261103000000_group_piles.sql`: group batches (`can_add`, `added_by`), with contributors' copies in their own folders.
5. `20261104000000_safety.sql`: blocks, reports and `delete_account()`.
6. `20261105000000_board_font_desk.sql`: a batch's font and board, and `desk_layouts`.
7. `20261112000000_photo_social_description_background.sql`: likes and comments on single photos, batch description and background. The batch-level likes and comments tables from the first migration are left alone; the app never used them.
8. `20261114032925_reports_survive_account_delete.sql`: deleting an account no longer fails when an open report points at it.
9. `20261115230000_books.sql`: photobooks, the batches each uses, print orders and the private bucket for print PDFs.

The tests in `supabase/tests/database/` cover visibility, group batches, safety, boards/fonts/desks, photo likes and comments, and books.

**Email sign-in.** The app asks Supabase for a sign-in email whose link returns to `strewn://auth-callback`; the web viewer asks for one that returns to the page you were on (`site_url` and `additional_redirect_urls` in `config.toml` list `strewn://auth-callback`, `https://batches.space/**` and localhost). Tapping the link on the phone opens the app, and `AppModel.open` finishes sign-in. The link only works where it was asked for: it's a PKCE link, and the verifier stays on that phone or browser. In the Simulator, copy the link from the email and run `xcrun simctl openurl <device> "<link>"`, then tap Open. Supabase's built-in mailer sends only its default emails, which have a link and no code, and only a few emails an hour. To also get a six-digit code (the app accepts one, and `otp_length = 6` is already set), set up custom SMTP (Authentication, Emails, SMTP Settings, or `[auth.email.smtp]` in `config.toml`). Then turn on the template entries in `config.toml`, which use `supabase/templates/` with `{{ .Token }}`, and run `supabase config push`.

**Sign in with Apple** needs a paid Apple developer team. The app side is on: `project.yml` writes `Strewn/Resources/Strewn.entitlements` and `Config.xcconfig` has `APPLE_SIGN_IN = YES`. In Supabase, the Apple provider must be on (Authentication, Providers) with the bundle id `com.kevingeorge.strewn` under Client IDs. Native sign-in on the phone needs no secret key. Without the provider the Apple button shows but sign-in fails, so set `APPLE_SIGN_IN = NO` to hide it.

**Google Photos on the web** uses the Google Photos Picker API, which asks Google only for the specific photos a person picks (never `photoslibrary.readonly`). In Google Cloud Console, enable **Google Photos Picker API**, create an **OAuth 2.0 Web Client ID** with `https://batches.space` and `http://localhost:5173` under Authorized JavaScript origins, and set `VITE_GOOGLE_CLIENT_ID` in `web/.env.local` (and in Vercel if rebuilding remotely). Google Identity Services is loaded on demand only when someone clicks **Google Photos**.

**Google Photos in the iOS app** uses the same Picker API without any Google SDK (`Strewn/Services/GooglePhotos.swift`): OAuth 2.0 with PKCE in an `ASWebAuthenticationSession`, then Google's picker in a second web sheet that closes itself once the selection is done. In the same Google Cloud project, create an **OAuth client ID** of type **iOS** with bundle ID `com.kevingeorge.strewn` (team ID `7CK43PG7GZ`), and set `GOOGLE_IOS_CLIENT_ID = <id>.apps.googleusercontent.com` in `Strewn/Resources/Config.local.xcconfig`. The redirect is the client ID reversed (`com.googleusercontent.apps.<id>:/oauth2redirect`), which the web session catches itself, so Info.plist needs no URL scheme. Leave it empty to hide the option.

## Open choices

- Open follows, or follow requests for people who want them?
- New batches start as Only me. Followers could be the default instead.
- When to move shared copies from the Supabase bucket to R2 (`docs/storage-plan.md`).
- What, if anything, to charge for (`docs/money.html`, `docs/money1.html`).

## Next steps

App:

- Retry shared-copy uploads that failed while offline.
- Bring photobooks to iOS, and add payment and a printer (`docs/photobook-plan.md`).
- A widget showing a batch on the Home Screen, and exporting a whole batch.

Editing and camera:

- Check `CITemperatureAndTint` direction for non-RAW photos against a grey card, and tune the tone curve ranges against Lightroom-style expectations.
- Add a live histogram and clipping warnings to the editor (a `CIAreaHistogram` on the preview image).
- Before the Shoot tab comes back: on a real iPhone, confirm Bayer RAW and ProRAW formats are listed, check DNG dimensions and orientation, tune the filmic curve, and build real `.cube` LUTs for each look (for example in DaVinci Resolve against the log encoding in `ToneCurve`).
- A Locked Camera Capture extension (iOS 18) so the camera opens from the Lock Screen and Camera Control.
