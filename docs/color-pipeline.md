# Strewn color pipeline

How Strewn gets a film look without Apple's photo processing, and how it keeps color consistent.

**In one paragraph.** The camera shoots a single-frame Bayer RAW, so Smart HDR, Deep Fusion, Photographic Styles and Apple's tone mapping never run. Core Image demosaics it with every Apple rendering choice switched off and the RAW decoder pinned. The result goes into one fixed, scene-linear working space (linear Rec.2020, D65). A per-camera matrix evens out sensor differences. The film stock is then one fixed chain of math: dye crosstalk, per-layer characteristic curves with toe and shoulder, halation and grain. A fixed output transform takes it to 10-bit Display P3. Anything that would otherwise be decided automatically is decided once, at capture, and written into the photo's recipe: the decoder version, metering, white balance, camera profile and grain seed. The viewfinder runs the same chain on the video feed and teaches itself, shot by shot, to match the developed RAW.

## What "consistent" means here

1. **Same scene, same colors, on any iPhone.** No per-device rendering choices from Apple, plus a calibrated profile per camera module.
2. **Same photo, same pixels, forever.** A re-edit, a re-render after an app update, the shared copies and the Photos extension all produce the same result as the original capture.
3. **What you see is what you get.** The viewfinder shows the film look the photo will get.
4. **Across lighting, film behaves like film.** By default each stock keeps its own white balance (daylight 5500 K, tungsten 3200 K), so a lamp-lit room looks warm on a daylight stock, the way real film does.

## Bayer RAW is the default; ProRAW is an option

| | Bayer RAW (default) | Apple ProRAW | HEIF |
| --- | --- | --- | --- |
| What it is | One unprocessed sensor readout | Apple's multi-frame merge as a linear DNG | Apple's finished picture |
| Apple processing | None | Merge, noise reduction and demosaic are baked in. The local tone map is stored as metadata, and we switch it off. | All of it, including Photographic Styles |
| Color consistency | Best: predictable per frame | Good, not guaranteed | Not consistent |
| Low light | Noisier (single frame) | Much cleaner | Clean |

Why Bayer RAW is the default: Apple's own engineer says ProRAW uses "multi-image fusion techniques" and is "not the appropriate format" when you need exposure-proportional, predictable values; they recommend Bayer RAW for that. Consistency is the brief, so the plainest input wins. ProRAW stays one tap away for low light, and the viewfinder label says so. (Source: Apple Developer Forums thread 825883, answer from Apple DTS.)

ProRAW is only switched on while it's the chosen format. With it off, the photo output lists Bayer formats only and runs the plainest pipeline.

## Apple processing and how each piece is avoided

| Apple processing | How Strewn avoids it |
| --- | --- |
| Smart HDR, Deep Fusion, Photonic Engine merge | Bayer RAW-only capture: no processed companion image is requested |
| Photographic Styles | Same. iOS 27 betas applied styles to third-party processed captures (forum thread 837436); that only affects the HEIF fallback. *Inferred:* a Bayer readout can't carry a style. |
| Global tone curve (`boostAmount`) | Set to 0: linear output |
| Shadow boost (`boostShadowAmount`) | 0 |
| ProRAW local tone map (Smart HDR gain map) | `localToneMapAmount = 0` |
| Local contrast and detail (`contrastAmount`, `detailAmount`) | 0 where supported |
| Gamut squeeze | `isGamutMappingEnabled = false`; Strewn compresses gamut itself at the very end |
| Per-camera default noise reduction and sharpening | Fixed values per pipeline version, never the camera's defaults |
| Decoder changes in OS updates | `decoderVersion` pinned per photo (see below) |
| Content-aware distortion correction | Off on the photo output |
| Video HDR and local tone mapping in the viewfinder | Apple Log feed where a 4:3 Log format exists; otherwise video HDR off and `isGlobalToneMappingEnabled` on |

Kept on purpose: lens shading and distortion correction from the DNG's own opcodes. They are per-module calibration, not taste, and leaving them off would give color shading in the corners that differs per phone.

Constant color (iOS 18) was considered and isn't used. It needs the flash to fire, takes several seconds and is meant for processed captures. (Source: `isConstantColorSupported` docs.)

## The chain

```
DNG
 └─ CIRAWFilter: decoder pinned · boost 0 · shadow boost 0 · local tone map 0 · gamut map off
                 fixed NR/sharpening · lens opcodes on · frozen baseline exposure, metering, white balance
 └─ scene-linear, linear Rec.2020 (D65)
 └─ camera profile 3×3 (frozen into the recipe)
 └─ recipe light and color: contrast, highlights, shadows, whites, blacks, saturation, vibrance, vignette
      (global, in stops around middle grey: no local filters, so preview and export match at any size)
 └─ stock: crosstalk 3×3 → optional LUT (log space) → halation → per-layer H&D curves → print values
 └─ grain (density weighted, sized to the frame, seeded per photo)
 └─ to linear Display P3, out-of-gamut colors compressed toward their own luminance
 └─ 10-bit HEIC, Display P3
```

Code: `ColorPipeline.decodeRAW`, `ColorPipeline.finish`, kernels in `StrewnKernels.ci.metal`, stocks in `FilmLook.swift`, recipe and frozen state in `EditRecipe.swift`. `EditRenderer.render` is the only entry point for photos, and the camera calls it too. So the saved capture and a later re-edit are the same render, not two similar ones.

## What makes the color consistent

**One working space, whatever renders it.** Every kernel call is wrapped in `matchedFromWorkingSpace(to: linear Rec.2020)` and `matchedToWorkingSpace(from:)`. The math is identical in the camera's preview context, the editor's `MetalImageView`, the export context and the Photos extension, even though they're set up differently.

**Frozen develop (`DevelopState` in the recipe).** These are decided once at capture and stored:
- `pipelineVersion`, which math to render with.
- `decoderVersion`, the CIRAWFilter decoder (for example `"8.dng"`). Apple says the decoder version changes demosaic and noise reduction while "other parts of the pipeline are common" (forum thread 834485). Pinning it keeps detail and noise from changing under OS updates. We prefer the newest `.dng` variant, which reads the DNG's own color and noise metadata. RAW 9 (Core ML demosaic and denoise on the Neural Engine) is picked automatically where offered, so check its speed on device.
- `baselineExposure`, read from the DNG once.
- `meteringEV`. Apple's auto exposure picks shutter and ISO, then Strewn's own centre-weighted log-average meter sets brightness, plus your EV compensation. This removes Apple's per-device exposure targets. Manual ISO or shutter skips the meter, so the physical exposure is respected like a film camera.
- `whiteBalance`: film (the stock's balance), a fixed Kelvin, or the camera's auto white balance frozen as a chromaticity.
- `profileMatrix`, the camera profile actually used. Adding or refining a profile later never changes old photos.
- `grainSeed`, so grain is identical on every re-render.

Imports with no develop state get one derived deterministically from the file: the same file always gets the same state.

**Camera profiles (`DeviceProfile`).** CIRAWFilter already uses Apple's color matrices from each DNG. A ColorChecker-fitted 3×3 per camera module (keyed by DNG `UniqueCameraModel`, lens model and Bayer or ProRAW) removes what's left. The table is empty until someone shoots charts: identity means "Apple's matrices only". How to fit one: shoot a ColorChecker Classic in daylight, export `ColorPipeline.calibrationTIFF(dng:)`, read the 24 patch values, run `python3 tools/fit_device_matrix.py measured.csv`, and paste the printed line. The script white-balances on the grey patch, fits with each row summing to 1 (greys stay grey), and prints ΔE2000 before and after.

**Spatial effects sized to the frame.** Halation radius, grain size and vignette are fractions of the frame, not pixels. A 1600 px editor preview, a 48 MP export and a 12 MP export look alike at the same viewing size. When the preview is too small to resolve the grain, grain strength drops the way it does when you shrink a scan.

**One render path.** The capture, the editor, export, paste to pile and the Photos extension all go through `EditRenderer.render`.

## Versioning (so old photos re-render identically)

- `PipelineVersion.current = 1`, stored in every recipe's develop state. Recipe JSON format version is now `"2"`; decoding tolerates missing keys, so older recipes still open.
- **Frozen once a build ships:** every `*_v1` kernel, the `ColorPipeline.V1` constants, the v1 stock numbers in `FilmLook.all`, and any shipped LUT file.
- To change the look of new photos: add `*_v2` kernels and constants, bump `current`, add 2 to `supported`, and branch on `develop.pipelineVersion`. Old photos keep their version.
- Re-rendering an old photo at the new version is an explicit user action ("Update to new color"), never automatic.
- `ColorPipeline.fingerprint(develop)` (pipeline and decoder version) belongs in the shared copies' `render_hash` (storage plan, section 4).
- **Limit:** pinning the decoder and freezing our own math makes renders match to within GPU rounding. They are not guaranteed bit-identical across GPUs or OS versions; Core Image runs in half-float. Expect visually identical, not byte-identical. The render hash should key on inputs (source, recipe, fingerprint), not on output bytes.
- If an OS ever drops a pinned decoder version, the newest one is used instead. A future build should mark that photo "rendered with a newer decoder".

## Film stocks (v1 first guesses)

Each stock (`FilmLook`) has: balance (K), crosstalk 3×3, per-layer gamma and speed offset, toe, shoulder, print black and white, halation (amount, radius, tint, threshold), and grain (amount, clump size, chroma). Look strength below 100% interpolates every parameter from Neutral (white balance in mireds), which is still one render.

| Look | Balance | Character |
| --- | --- | --- |
| Neutral | 5500 K | Near-linear film curve, for editing |
| Warm 160 | 5500 K | Low contrast, warm mids, slightly cool shadows, long shoulder, fine grain, faint halation |
| Slide 50 | 5500 K | High saturation and contrast, dense blacks, crossover toward cool highlights, very fine grain |
| Tungsten 800 | 3200 K | For lamplight; strong red halation around lights; coarse grain |
| Mono 400 | — | Panchromatic black and white, deeper contrast, visible grain |
| Faded | 5500 K | Lifted blacks, lowered whites, pastel color |

The numbers are placeholders until they're tuned on a phone. The best way is against real film scans of the same scene (a ColorChecker plus skin and foliage), shot on the stocks being emulated. The look preview artifact runs this same math in the browser for picking stocks, not for final tuning.

## Viewfinder

`PreviewRenderer` runs, per frame:
1. To scene-linear. Apple Log is decoded with Apple's published curve (Rec.2020 primaries). Otherwise, a generic inverse display curve is applied to a feed with video HDR off and global tone mapping on.
2. Correction from `PreviewCalibrator`.
3. Strewn's meter, live and smoothed, plus EV compensation, the same meter the capture freezes.
4. `ColorPipeline.finish` with the same look: the identical code the photo goes through.

The device's white balance is locked to the develop's: the stock's Kelvin, the dial, or auto.

**Self-calibration.** At each shutter press, the viewfinder's scene-linear sample and the developed RAW's are compared channel by channel. This uses sorted values, so the video and photo don't need to line up, and orientation doesn't matter. The difference becomes a per-channel curve correction at 7 points from −6 to +6 stops, learned 30% per shot and stored per camera module and feed type on the phone. The viewfinder gets closer with every photo.

## Already-processed images (imports, HEIF fallback)

Apple's tone mapping is baked into these, so they can't be fully consistent. `decodeProcessed` undoes a generic filmic curve on luminance and keeps the chroma, so the film stages behave about the same as on RAW. The viewfinder label says "color not consistent" in HEIF mode.

## Needs a real iPhone to check

1. **Linearity.** Shoot a step wedge, or bracket a grey card at 1-stop steps. With `boostAmount = 0`, each stop should double the decoded value. If not, CIRAWFilter still applies a base curve, and we'd need to undo it.
2. **White balance properties.** Setting `neutralChromaticity` then reading `neutralTemperature` (used for the temperature slider on auto WB) should round-trip. Check the sign of `neutralTint`.
3. **Decoder versions.** Check what `supportedDecoderVersions` returns for iPhone Bayer and ProRAW DNGs, and their raw-value format (the code assumes "8", "8.dng", "9.dng"). Check RAW 9's speed at 12 and 48 MP.
4. **Bayer RAW resolution.** Check whether Bayer RAW is 12 MP (binned) or 48 MP on 48 MP sensors, and whether `photoQualityPrioritization` needs to be `.speed` for RAW-only Bayer capture.
5. **Apple Log preview.** Check whether any 4:3 Log format offers Bayer RAW. If Log formats are all 16:9 (likely), the display-feed path is used. Check `isGlobalToneMappingSupported` on the photo format.
6. **Cross-device spread.** Shoot the same ColorChecker scene on two or three iPhones. Compare mean ΔE2000 with and without fitted profiles. The goal is under 2 average.
7. **Preview vs photo.** After 10 to 20 shots, compare the viewfinder against the saved photo side by side. The calibrator should converge; check it doesn't oscillate.
8. **ProRAW BaselineExposure.** Check whether it varies per scene. In manual exposure that would make ProRAW brightness drift. If so, pin it per device.
9. **Speed.** Full-resolution develop time at capture, and viewfinder frame rate with halation on (one Gaussian blur per frame).
10. **Photos extension memory.** Full-resolution RAW renders inside the extension's memory limit.

## Changes needed outside this thread's files

- `EditorModel.revertToOriginal()`: use `recipe = recipe.reverted()` instead of `.identity`, so revert keeps the photo's frozen develop state (white balance, metering, profile, grain seed).
- `AppModel.render(_:into:)`: when the recipe is identity, keep `photo.edit = recipe` (with its `develop`) instead of `nil`. Saving edits should store `try editRenderer.pinned(recipe, for: source)` so imports get pinned to a pipeline version on first save.
- `MetalImageView` (optional): give its CIContext `.workingFormat: .RGBAh`. The pipeline no longer depends on the context's working space.
- `EditRenderer.renderLadder` (storage plan): include `ColorPipeline.fingerprint` in `render_hash`.
- README: the "Camera and color pipeline" section describes the old develop and should point here. Mention `tools/fit_device_matrix.py`.

## Sources

- CIRAWFilter properties and decoder versions: developer.apple.com/documentation/coreimage/cirawfilter and /cirawdecoderversion (read October 30, 2026).
- Decoder version scope and RAW 9 vs RAW 9 DNG: Apple Developer Forums thread 834485 (Apple engineer replies).
- RAW 9 in Core Image: WWDC26 session 305. Photo capture formats: WWDC26 session 304.
- ProRAW vs Bayer radiometry: Apple Developer Forums thread 825883 (Apple DTS).
- Constant color: AVCapturePhotoOutput `isConstantColorSupported` docs.
- `AVCaptureColorSpace` (Apple Log; Apple Log 2 deactivates photo output): developer.apple.com.
- Apple Log curve constants: colour-science, `colour/models/rgb/transfer_functions/apple_log_profile.py`.
- Photographic Styles on third-party captures in iOS 27 betas: Apple Developer Forums thread 837436 (developer report, no Apple reply).

Inferred rather than read: that `boostAmount = 0` gives fully linear output; that Bayer captures can't carry Photographic Styles; the exact `CIRAWDecoderVersion` raw-value strings; the names of the global tone mapping and video HDR properties (from memory of the AVFoundation API; the docs page didn't render here).
