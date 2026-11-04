# Strewn

Working name for a social photo app with two halves:

1. **Desk piles.** Every album, day trip or shoot sits on your desk as a loose pile of prints with a cover you choose on top. Tap it and the prints fly out into a scrolling gallery with the frame style the owner picked (white border, thin black, Polaroid, film strip, gallery mat, or none).
2. **A camera with its own color.** Shoots Bayer RAW or Apple ProRAW so Apple's processing (Smart HDR, Deep Fusion, Photographic Styles) stays out of the picture, then develops the RAW with a custom Core Image pipeline and film looks.

3. **An editing workspace.** Non-destructive editing on top of the untouched original (the DNG for Strewn captures): film looks with strength, light, color, effects and an optional crop, with undo, hold-to-compare, copy/paste across a whole pile, and revert.

The interactive design mockup is published separately as an Artifact ("Strewn Prototype"); it is only a clickable preview. The app itself is native Swift and SwiftUI, and this folder is its starter code.

## Native iOS

Everything runs on Apple's own frameworks, with no web views:

| Area | Frameworks |
| --- | --- |
| UI, transitions, haptics | SwiftUI (`matchedGeometryEffect`, `Layout`, `scrollTargetBehavior`, `sensoryFeedback`, context menus) |
| Capture | AVFoundation: `AVCapturePhotoOutput` with Bayer RAW and Apple ProRAW, manual ISO, shutter and white balance |
| Hardware shutter | `onCameraCaptureEvent` (AVKit, iOS 18): Camera Control and volume buttons take the picture |
| Develop and edit | Core Image (`CIRAWFilter`, built-in filters, custom Metal CI kernels), MetalKit preview |
| Library | PhotosUI `PhotosPicker` to start piles; PhotoKit to save RAW + HEIF captures and to write edits back as revertible Photos edits (`PHContentEditingOutput` with the recipe as adjustment data) |
| Photos extension | "Edit with Strewn" inside the Photos app (`PHContentEditingController`), sharing the same editor and pipeline |
| Sharing | `ShareLink` with a `Transferable` that renders the full-resolution edit on demand |
| Copy/paste edits | `UIPasteboard` with a custom type, so a copied recipe survives between sessions |

## Core rule: full frame, never cropped

Instagram-style square and 4:5 crops are the thing this app exists to avoid. Every view shows the whole photo at its native aspect ratio.

- `Photo` stores `pixelWidth` and `pixelHeight`, so layout knows each photo's shape before the image loads.
- `PhotoImage` is the only view that draws a photo. It uses `.aspectRatio(photo.aspectRatio, contentMode: .fit)` and never `.fill` or `scaledToFill`. Don't add another image view; reuse this one.
- In the single-column gallery each photo is capped to the visible height minus its frame, so a tall portrait is shown whole on one screen instead of running off the bottom. Width follows from the aspect ratio.
- The two-column layout is a masonry `Layout` (`MasonryLayout`), so photos keep their own heights instead of being cut to equal tiles.
- Frames only add space around a photo (`FrameStyle.insets`); they never change its shape.
- Desk-pile prints keep their true proportions too (panoramas are wide prints, portraits narrow).
- The camera preview shows the full 4:3 sensor frame, letterboxed, and the full-screen viewer is letterboxed on black.
- The film roll keeps each frame's own width at a shared height, so nothing is trimmed to fit a fixed film gate.
- The editor's crop is opt-in. "Original" is the default and keeps the whole frame; the gallery and viewer label a photo as cropped only when its owner chose a crop.

## Getting started

Requirements: Xcode 16, iOS 17+, and a RAW-capable iPhone for the camera (Pro models for ProRAW).

```sh
brew install xcodegen
cd gallery-app
xcodegen generate
open Batches.xcodeproj
```

The app runs on the `MockBackend` with sample data until you put real values in `Strewn/Resources/Config.xcconfig` (demo mode). In demo mode, sign in with any email and any six-digit code; you become `@kevin` with three sample friends. The sample photos point at picsum.photos placeholders at a mix of aspect ratios.

This scaffold was written without a Mac, so it has not been compiled yet. Expect a few small fixes on the first build.

## Layout

```
gallery-app/
├── project.yml                     XcodeGen spec: app + Photos editing extension, supabase-swift, Metal CI kernel flags
├── Extensions/PhotoEdit/           PHContentEditingController hosting the same EditorView
├── supabase/config.toml            Supabase CLI config (auth: six-digit email codes)
├── supabase/migrations/            Accounts, follows, piles, sharing, row level security, the media bucket
├── supabase/storage.sql            The R2 storage plan's tables and functions (draft, not a migration yet)
├── supabase/tests/                 pgTAP test of who sees what (database/), runner for linked projects
└── Strewn/
    ├── App/                        App entry, RootView tabs, AppModel (@Observable), theme + desk mat
    ├── Models/                     User, PhotoCollection, Photo, FrameStyle, EditRecipe, SampleData
    ├── Features/
    │   ├── Desk/                   Your desk: profile header and the grid of piles
    │   ├── DeskPile/               DeskPileView, PrintView, PileLayout, FilmRollPileView (canister + curled strip), PileRotation
    │   ├── Gallery/                GalleryView, FilmRollView, PhotoImage, PhotoFrame modifier, FramePickerSheet, FullFrameViewer, MasonryLayout
    │   ├── Editor/                 EditorView (workspace UI), EditorModel (recipe, undo, compare, copy/paste, preview)
    │   ├── NewPile/                NewPileSheet (PhotosPicker import)
    │   ├── Friends/                Friends' piles feed
    │   └── Camera/                 CameraScreen (+ hardware shutter, tap to focus), CameraModel, PreviewRenderer (CAMetalLayer, drawn per camera frame)
    ├── Editing/                    EditRenderer (recipe → image), MetalImageView, PhotosEditSaver
    ├── Camera/
    │   ├── CameraController.swift  AVCaptureSession, AVCapturePhotoOutput, RAW settings, manual ISO/shutter/WB
    │   ├── PhotoSaver.swift        Saves developed HEIF + DNG alternate to Photos
    │   └── ColorPipeline/          ColorPipeline, FilmLook, ToneCurve, CubeLUT, StrewnKernels.ci.metal
    ├── Services/                   Backend protocol, MockBackend, SupabaseBackend
    └── Resources/                  Info.plist (camera/photos usage strings), Config.xcconfig, Looks/*.cube
```

`PhotoCollection` is named that way so it doesn't collide with Swift's `Collection` protocol.

## How the pile spreads into the gallery

- Each print in `DeskPileView` has `matchedGeometryEffect(id: photo.id, in: namespace)`. The matching photo in `GalleryView` uses the same id, so SwiftUI moves and resizes it from the pile to its gallery slot.
- Prints are placed with `.position` (not `.offset`) so the matched frame is where the print really is. Rotation is applied after the matched effect, and the gallery photo carries a `pileRotation(angle)` transition that turns it from its pile angle to upright, and back on close.
- `PileLayout` derives each print's angle, offset and width from the photo's UUID, so a pile looks the same everywhere and only reshuffles when the cover changes.
- While a pile is open its grid slot is kept as an empty square so the desk doesn't reflow.
- The gallery uses `LazyVStack`; photos far off screen just fade. For very large piles, limit the hero animation to the photos in the pile stack, which the code already does.
- **Closing.** The back button, or pull down to put the pile back. `pullDownToDismiss` (Gallery/PullDownToDismiss.swift) reads the scroll view's overscroll with `onScrollGeometryChange` and the moment the finger lifts with `onScrollPhaseChange`. Only a pull that starts while already at the top counts, so it never fights scrolling down the gallery or the film roll, or the bounce at the end of a fling. As you pull, the photos shrink toward the desk (a render-only `scaleEffect`) and the wall fades; past 90 pt there is a light haptic tick, and letting go there sends the photos back onto the pile with the same matched-geometry animation. Letting go earlier springs back. Dragging the header down does the same from any scroll position, and VoiceOver's escape gesture closes too. Reading the scroll needs iOS 18, so on iOS 17 only the header drag and the back button close a pile.

## Film roll piles

Choosing the film strip frame turns the whole pile into film:

- **Collapsed:** `FilmRollPileView` draws a 35mm canister with the cover pulled out first and the next frames chained end to end, curling under (`FilmRollLayout` walks along the strip, turning each frame by its bend). Frames keep their true widths, so a panorama is a long frame.
- **Expanded:** `FilmRollView` is one continuous roll on a single black film base, with frames separated only by film base and edge numbers printed on the film. It has two directions, set by `FrameStyle.rollDirection` and switchable with the Down / Sideways control at the top:
  - **Down (default).** A vertical `LazyVStack` you scroll with your thumb like any feed. Perforations run down both sides (`SprocketHoles(axis: .vertical)`), so every frame gets nearly the full screen width, and the meta row and Edit/cover buttons sit under each frame. Frames are capped so a tall portrait still fits on screen whole.
  - **Sideways.** A horizontal `ScrollView` with perforations along the top and bottom and `.viewAligned` snapping frame by frame. The meta row follows the centered frame. Strip height is the tallest that still shows a 3:2 frame whole, so turning the phone sideways gives a bigger strip.
- The same `matchedGeometryEffect` ids connect the strip in the pile to the roll in either direction, with each frame unrotating from its curl angle.

## Editing workspace

`EditRecipe` is the whole edit: look and strength, exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, grain, vignette, fade, aspect and straighten. It is stored on the `Photo` (and in the backend as JSON), never baked into the original.

- **Source.** `Photo.editSourceURL` is the DNG for Strewn captures, otherwise the untouched original file. For RAW, exposure and white balance go back into `CIRAWFilter`, so editing is a true re-develop from sensor data.
- **Render order** (`EditRenderer`): RAW develop or decode → look (blended by strength against Neutral) → highlights/shadows → 5-point tone curve (contrast, whites, blacks, fade) → vibrance and saturation → vignette → grain → straighten → crop to the chosen aspect.
- **Live preview.** Renders off the main thread at 1600 px on the long side, in RAW draft mode while a slider is moving, shown through `MetalImageView` (aspect fit).
- **Workspace.** Looks, Light, Color, Effects and Crop tools; a dot on each changed adjustment; undo and redo per gesture; press and hold the photo to compare with the original; Reset per slider; Revert to original.
- **Copy and paste.** Copy puts the recipe on the system pasteboard. Paste, or "Paste edits to whole pile", applies everything except each photo's own crop.
- **Saving.** Done renders a full-resolution 10-bit HEIF next to the original. When the photo is also in the Photos library (imports and captures), the edit is written there as a revertible edit with the recipe as adjustment data, so Photos shows "Edited", can Revert, and Strewn can reopen it with the sliders where they were.
- **In the Photos app.** The `StrewnPhotoEdit` extension hosts the same `EditorView`, so any library photo can be edited with Strewn's looks. Photos provides Cancel and Done there. Extensions have a tight memory limit, so full-resolution RAW renders there may need tiling or a lower scale factor; check on device.

## Frames and covers

`FrameStyle` (kind, border width, wall color, layout) is stored on the collection as JSON, so the owner decides how everyone sees the pile. Owners get a Frames button and a star on each photo to set the cover; viewers get neither. The `.photoFrame(_:caption:frameNumber:)` modifier draws each style: Polaroid uses the photo caption in the bottom margin, film strip draws perforations and edge numbers with `Canvas`.

## Camera and color pipeline

**Capture.** `CameraController` uses a physical `.builtInWideAngleCamera` because Bayer RAW is not available on the virtual dual/triple camera; lens switching swaps physical devices.

| Mode | What you get | Apple processing |
| --- | --- | --- |
| Bayer RAW (default) | One unprocessed sensor readout as DNG | None |
| Apple ProRAW | Apple's multi-frame merge as linear DNG | Merge and noise reduction yes, tone mapping skipped at develop |
| HEIF | Apple's finished image | Full; our look is applied on top |

**Develop.** `ColorPipeline.develop(dng:settings:)`:

1. `CIRAWFilter` demosaics into scene-linear Display P3 with `boostAmount = 0`, `boostShadowAmount = 0`, `localToneMapAmount = 0`, gamut mapping off, and extended dynamic range kept. White balance comes from the WB dial through `neutralTemperature`.
2. `strewnGrade` (Metal CI kernel): warmth, saturation, monochrome in linear light.
3. Optional creative 3D LUT per look: log encode → `CIColorCube` → log decode. Drop `.cube` files in `Resources/Looks` (see the README there for the expected encoding).
4. `strewnFilmic`: S-curve through middle grey with a toe and a highlight shoulder, so highlights roll off like film instead of clipping.
5. Soft-light grain, then a 10-bit HEIF in Display P3. The DNG is saved alongside as the RAW alternate so the look can be changed later.

The live preview runs the same grade and LUT on video frames through an `MTKView`. Those frames have already been through Apple's video pipeline, so the preview is a close guide and the saved photo, developed from RAW, is the real result.

Looks in the scaffold: Neutral, Warm 160, Slide 50, Tungsten 800, Mono 400, Faded. The parameters are first guesses to tune on device.

## Accounts and sharing

What works in the code:

- **Sign-in**: an emailed six-digit code (Supabase Auth), or Sign in with Apple once it's switched on (below). The first sign-in asks for a name and a unique @handle, checked as you type.
- **Profiles and following**: find people by name or handle, open their profile, follow or unfollow. Follows are open (no requests), like Instagram's public accounts.
- **Who can see a pile**: every pile starts as **Only me**. Share sets it to **Specific people** (only the people you add), **Followers** (your followers plus anyone you add), or **Anyone on Strewn** (anyone signed in). The rule lives in the database (`private.can_view_collection`, in `supabase/migrations/`), so the app can't show a pile to the wrong person even if the app has a bug. `MockBackend` follows the same rule, so demo mode behaves the same way.
- **Friends feed**: piles from people you follow, plus piles shared with you directly ("Shared with you").
- **Links**: `strewn://pile/<id>` opens a pile for anyone who can already see it. The share sheet sends one.
- **Shared copies**: when a pile is shared, the phone makes three HEIC copies of each photo (320, 800 and 1800 px on the long edge, no location or other metadata) and uploads them. RAW files and originals never leave the phone; `LocalLibrary` remembers where they are, and the server only knows the shared copies' path. Edits to a shared photo upload fresh copies.

### Try it now (no server)

Build and run as in Getting started. With the placeholder `Config.xcconfig` the app is in demo mode: sign in with any email and code `123456`, then open a pile and tap Share, or go to Friends and tap Find people. Demo data resets on relaunch.

The web prototype shows the same flow.

### Run it against Supabase

The live project is **strewn** (ref `exogbxkigwptelpbdaib`, us-west-1, free plan), with the migrations applied. The app uses `SupabaseBackend` whenever real values are configured, and `MockBackend` (demo mode) otherwise.

**Point the app at it.** Real keys never go in `Config.xcconfig`, which keeps placeholders and is safe to commit. Create `Strewn/Resources/Config.local.xcconfig` (gitignored); `Config.xcconfig` includes it:

```
SUPABASE_URL = https:/$()/exogbxkigwptelpbdaib.supabase.co
SUPABASE_ANON_KEY = sb_publishable_...
```

The `$()` stops xcconfig from treating `//` as a comment. Use the project's **publishable** key (Project Settings, API Keys), or the legacy anon key. Never the secret or service_role key. Then build and run. Sign out of demo mode first if you were in it.

**Database changes** go through the Supabase CLI (`brew install supabase/tap/supabase`, then `supabase login`):

```bash
supabase link --project-ref exogbxkigwptelpbdaib
supabase migration new <name>      # write SQL in the new supabase/migrations file
supabase db push                   # apply new migrations to the linked project
supabase/tests/run-linked.sh       # pgTAP visibility test against it, rolled back, no Docker
```

With Docker running you can use `supabase start` and `supabase test db` for a local stack instead. `supabase test db --linked` also needs Docker (for pg_prove), which is why `run-linked.sh` exists. The test creates six people, follows, piles, a shared photo and its copy, checks what each person can read and write (38 checks), and rolls everything back.

What the migrations set up:

1. `20261101000000_social_schema.sql`: profiles, follows, piles (`collections`), `collection_members`, photos, likes, comments, count triggers, and the row level security behind the four visibility levels. Signed-out requests read nothing.
2. `20261101000100_shared_copies_bucket.sql`: the private `media` bucket (HEIC only, 5 MB) and its policies. You write only your own `{you}/...` folder, and you read a copy only if you can see its pile.
3. `20261101000200_tighten_functions_and_policies.sql`: changes from the database advisors. `can_view_collection` moves to an unexposed `private` schema, trigger functions can't be called over RPC, owner policies are split by action, and missing foreign-key indexes are added.

**Email sign-in.** The app asks Supabase for a sign-in email whose link returns to `strewn://auth-callback` (`site_url` and `additional_redirect_urls` in `config.toml`). Tapping the link on the phone opens Strewn, and `AppModel.open` finishes sign-in. The link only works in the app install that asked for it: it's a PKCE link, and the verifier stays on the phone. In the Simulator, copy the link from the email and run `xcrun simctl openurl <device> "<link>"`, then tap Open. Supabase's built-in mailer on the free plan sends only its default emails, which have a link and no code, and only a few emails an hour. To also get a six-digit code (the app accepts one, and `otp_length = 6` is already set), set up custom SMTP (Authentication, Emails, SMTP Settings, or `[auth.email.smtp]` in `config.toml`). Then uncomment the template entries in `config.toml`, which use `supabase/templates/` with `{{ .Token }}`, and run `supabase config push`.

`storage.sql` stays a draft until image storage moves to R2. Then add it as the next migration. `supabase/tests/supabase-stubs.sql` lets you try the migrations plus that draft on a plain Postgres.

### Turn on Sign in with Apple

Needs a paid Apple developer team.

The app side is on: `project.yml` attaches `Strewn/Resources/Strewn.entitlements` and `Config.xcconfig` has `APPLE_SIGN_IN = YES`. The one step left is in Supabase: Authentication, Providers, turn on Apple and add the bundle id `com.kevingeorge.strewn` under Client IDs. Native sign-in on the phone needs no secret key. Until that's done the Apple button shows but sign-in fails, so set `APPLE_SIGN_IN = NO` to hide it.

### Where shared copies live

For now, shared copies go to the private `media` bucket in Supabase Storage at `{owner}/{photo}/{revision}/{s|m|l}.heic`, and viewers get signed links that expire after six hours. Storage rules let you write only your own folder and read copies only of piles you can see. `docs/storage-plan.md` describes the longer-term setup (Cloudflare R2 behind a CDN, four sizes, cheaper at scale). Moving to it only changes `publish` and how `SupabaseBackend` signs links.

### Open choices

- Open follows, or follow requests for people who want them?
- Can people a pile is shared with add their own photos to it (a group pile), or only look? Right now they only look.
- New piles start as Only me. Followers could be the default instead.
- When to move shared copies from the Supabase bucket to R2.

`SupabaseBackend` sits behind the small `Backend` protocol, so swapping to Firebase or a custom API later touches one file.

## Next steps

Editing and native:
- Check `CITemperatureAndTint` direction for non-RAW photos against a grey card, and tune the tone curve ranges against Lightroom-style expectations.
- Add a live histogram and clipping warnings to the editor (a `CIAreaHistogram` on the preview image).
- Batch export a pile, and a widget showing a pile on the Home Screen.
- A Locked Camera Capture extension (iOS 18) so Strewn opens from the Lock Screen and Camera Control.

App:

1. Generate the Xcode project, fix first-build errors, and run the desk and gallery on the simulator with sample data.
2. On a real iPhone, confirm Bayer RAW and ProRAW formats are listed with ProRAW enabled, and check DNG dimensions and orientation.
3. Tune the filmic curve and build real `.cube` LUTs for each look (for example in DaVinci Resolve against the log encoding in `ToneCurve`).
4. Cache shared images (swap `AsyncImage` for a cached loader that still only fits, never fills), and retry shared-copy uploads that failed while offline.
5. Pile editing after creation: add or remove photos and reorder the roll (creation from the library is in `NewPileSheet`).
6. Social: likes and comments (tables and rules exist, no UI yet), and a public web page for a pile, full frame.
