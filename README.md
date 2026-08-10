# PixelBoost

A small iOS app for upscaling and editing photos, fully on-device (Neural
Engine/GPU via Core ML and Vision, no network call required) — started as
a pure super-resolution app and is growing into a broader photo editor
(background removal now, more editing tools planned). There's a separate,
optional server (`server/`) for debug logging, temporary cloud backup, and
custom presets — see "Logging & cloud features" below.

**Requires iOS 17** — Remove Background (Cutout) uses Vision's
`VNGenerateForegroundInstanceMaskRequest`, which iOS 16 doesn't have.

Ships with five real converted super-resolution models (see
[`Models/README.md`](Models/README.md)) — Real-ESRGAN's general-photo
`x4plus`, anime/illustration-optimized `anime_6B`, low-artifact portrait
`RealESRNet_x4plus`, and the fast/lightweight `realesr-general-x4v3` (all
BSD-3-Clause), plus BSRGAN (Apache-2.0) for 3D/CG renders specifically —
same RRDBNet family, trained on a much harsher synthetic degradation
pipeline so it's more robust on a genuinely noisy/degraded render than a
model trained assuming a clean real photo — plus a plain Lanczos-resampling
fallback (`LanczosUpscaler`) so the app still works if a model is ever
missing/swapped out. An Auto mode runs every bundled model (now five) on
the *full* photo and shows every result so you can compare and pick the
one you like, rather than a heuristic quietly deciding for you — see
"Compare Models" below. A sixth model (Apache-2.0, converted from Intel
Open Image Denoise) backs the separate **Render Denoise** tab for cleaning
up 3D-render noise — see "Render Denoise" below and
[`Models/README.md`](Models/README.md).

---

## Features

- **Bottom tab bar** — every screen (Upscale plus all thirteen editing tools,
  plus Batch/Cloud/History/Settings) is its own tab in a horizontally
  scrollable bar along the bottom, instead of tools being buried behind a
  menu or a top toolbar. There are eighteen tabs, more than the ~5 a native
  iOS tab bar shows before collapsing the rest into an auto-generated
  "More" list, so this is a custom bar rather than `TabView`. Every tab
  stays mounted the whole time you have the app open, so switching away
  and back never loses whatever you were in the middle of (a crop
  selection, paint strokes, slider positions):
  - **Cutout** — cuts the main subject(s) out of a photo with a
    transparent background, using Vision's on-device subject-lifting API
    (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+) — the same
    technology behind Photos' own "Lift Subject." No custom model needed.
    Once the result has transparency, a **Background** strip appears
    right below it — seven curated fills (five solid/gradient swatches,
    plus a blurred copy of the original photo, the common "fake bokeh"
    trick) to place behind the cutout subject. Not a generative
    "AI-replace the background with a new scene" model — see "Known
    simplifications" below.
  - **Enhance** — one-tap automatic exposure/color correction via Core
    Image's built-in `autoAdjustmentFilters` (the same auto-analysis API
    behind Snapseed's "Tune Image" auto button and Photoshop Express's
    "Auto Enhance") — no manual sliders, no custom model.
  - **Adjust** — brightness/contrast/saturation/exposure/vignette, plus a
    5-point tone curve (drag a point up/down to reshape tones at that
    brightness level — the input positions are fixed so points can't cross
    over each other and fold the curve back on itself), all with a live
    preview.
  - **Selective** — the same brightness/contrast/saturation/exposure
    adjustments as Adjust, but paint a region first and they apply only
    there, blended back over the untouched original everywhere else.
  - **Crop & Rotate** — 90° rotate plus fixed-ratio crop (Free/1:1/4:5/
    5:4/16:9/9:16); drag the crop window to reposition it.
  - **Filters** — thirteen one-tap looks (Vivid, Mono, Noir, Silvertone,
    Chrome, Process, Transfer, Instant, Fade, Sepia, Warm, Cool, Matte)
    built from Core Image's built-in photo-effect filters (plus a few
    hand-tuned `CIColorMatrix`/`CIToneCurve` combinations for Warm/Cool/
    Matte), picked from a strip of thumbnails rendered against your actual
    photo, not generic swatches.
  - **Overlays** — add text (and, via the system keyboard's own emoji
    key, "stickers") on top of a photo; drag to reposition, tap to edit
    color/size/font/outline/shadow or delete. Eight fonts (System,
    Helvetica, Georgia, Courier, Typewriter, Script, Marker, Noteworthy),
    all genuinely bundled with iOS — no custom font files.
  - **Erase** (object removal) — paint over something to erase it; the
    marked area is filled in with a diffusion-based fill that pulls
    color inward from the surrounding pixels — not a generative model,
    see "Known simplifications" below.
  - **Restore** — a denoise slider (Core Image's built-in
    `CINoiseReduction`) plus a "Restore Faces" toggle that sharpens detail
    just around faces Vision detects (`VNDetectFaceLandmarksRequest`) — a
    classical detail boost, not a trained restoration model (GFPGAN/
    CodeFormer-class); see "Known simplifications" below.
  - **Render Denoise** — a genuine trained model (converted from Intel Open
    Image Denoise's `rt_ldr_small` filter, Apache-2.0 — the same one
    Blender's Cycles Denoise node uses), for cleaning up noise from a 3D
    render (Cycles, Eevee, any other path tracer) rather than a real
    photo's sensor grain, which Restore's `CINoiseReduction` slider is
    tuned for instead. Fixed-strength, one Apply action — no slider, since
    the model has no adjustable parameter.
  - **Clone Stamp** — tap a source point, then paint elsewhere to copy
    pixels from a fixed offset relative to that point (the offset is set
    once, from the source point and the first spot you paint, then stays
    constant for every stroke after that — the standard clone-stamp
    gesture). Implemented as one whole-image shift (`CIAffineTransform`)
    composited back over the original only within the painted area
    (`CIBlendWithMask`), rather than sampling pixel-by-pixel along the
    drag — same result, since the offset never changes mid-stroke anyway.
    Tap "Change Source" to pick a new area at any time.
  - **Pixel Art** — converts the photo into a blocky retro look: shrink to
    a small grid (block size 3-32px), optionally crush the palette down to
    2-16 posterized color steps per channel (`CIColorPosterize`), then
    scale back up with nearest-neighbor interpolation so every block reads
    as one hard-edged square instead of a blurry resize. An optional faint
    grid overlay makes the block boundaries explicit.
  - **Scripted Filter** — write or paste a small Lua script defining
    `apply(r, g, b, a)` (each 0...1 in, 4 numbers 0...1 out) and run it
    over the photo one pixel at a time — a genuinely user-programmable
    filter, not another fixed preset. Backed by a vendored, sandboxed Lua
    5.4 interpreter (`Vendor/Lua`, MIT-licensed — see
    `LuaFilterEngine.swift`): only `base` (with `load`/`dofile`/`loadfile`
    stripped back out), `string`, `table`, `math`, and `utf8` are opened —
    no filesystem, process, network, or bytecode-loading access — and a
    per-run instruction-count hook aborts a script that's still running
    past 5 seconds, so a `while true do end` typo can't hang the tool.
    Runs at up to 900px on the longest side (capped — a full-resolution
    photo would mean millions of individual Lua calls), same "known,
    deliberate simplification" reasoning as the Filters/Adjust previews.
    Named scripts save locally (`ScriptedFilterStore`, plain
    `UserDefaults`, no server/iCloud round-trip) so they're there again
    next launch; ships with three ready-to-run examples (Invert, Red
    Channel Only, Threshold).

  Each editing tab has an **Apply** button instead of a Done/Cancel —
  applying bakes the edit onto the shared result and resets that tab back
  to a blank slate (fresh sliders, empty overlay layer, cleared brush
  strokes), but you stay right there; there's no dismiss step, you just
  tap another tab whenever you want to move on. Cutout is the one
  exception — it's a single unattended action, not something with
  in-place controls, so it just runs and updates in place. All twelve
  chain onto whichever result is currently showing (crop the upscaled
  photo, filter a cutout, etc.) rather than always reaching back to the
  original photo.
- **Compare Models** — with Auto selected, Upscale runs the whole photo
  through every bundled model and shows every result in a tappable,
  full-screen-viewable grid; pick whichever looks best, or save them all.
- **2x/3x/4x output scale** — every model natively super-resolves at 4x
  (that's fixed by the architecture), then the result is resized down to
  your chosen final size — so 2x/3x still benefit from the model's full
  detail instead of skipping analysis to hit a smaller ratio directly.
- **Before/after comparison slider** — drag to reveal, right on the main
  screen once a photo's upscaled.
- **Denoise before upscale & sharpen after** (Settings) — an optional
  `CINoiseReduction` pass on the source photo right before it's handed to
  the model (helps avoid amplifying sensor noise into upscaled speckle on
  grainy/low-light photos), and an optional `CISharpenLuminance` pass on
  the finished result. Both off by default, both apply to single-photo and
  Batch upscales alike.
- **Revert to Original** — one tap on the main screen backs a chain of
  edits (upscale, crop, filter, whatever) all the way out to the
  untouched original photo you picked, without re-picking it.
- **Text watermark** (Settings) — draw your own text over a chosen corner
  (or center) of every saved photo, with an opacity slider. Applies to
  every save path: single photo, Batch, and Compare Models' "Save All."
- **Auto-Save After Upscale** (Settings) — skip the Save tap for a
  single-photo upscale; saves itself the moment it finishes.
- **Preserve Original** (Settings) — opts back out of the overwrite-in-
  place default below, so every save always adds a new photo instead.
- **Accent color** (Settings) — eight curated color themes beyond the
  default blue, applied app-wide; see "Known simplifications" for why it
  takes effect on next launch rather than live.
- **Default landing tab** (Settings) — choose which tab PixelBoost opens
  to instead of always starting on Upscale.
- **Save overwrites the original by default** — saving a result (single
  photo or batch) replaces the original photo you picked in place, rather
  than adding a second, duplicate copy next to it. Uses `PHContentEditingOutput`
  keyed off the `PhotosPickerItem`'s asset identifier, which needs full
  Photos read/write access (not just add-only) — falls back to adding a
  new asset instead if that's declined, the identifier's missing, or the
  original can't be found (e.g. deleted since picking), so saving never
  just fails outright. "Save All" on a Compare Models grid is the one
  exception and always adds new assets, since there's no single result
  there to overwrite the original with.
- **Export format & quality** (Settings) — Auto (PNG if the result has
  real transparency, JPEG otherwise), or force HEIC/JPEG/PNG, plus a
  shared quality slider for whichever lossy format ends up being used.
  Applies to every save — single photo, batch, and Compare Models' "Save
  All."
- **Model & quality picker** (Settings) — Auto, General Photo, Anime /
  Illustration, Portrait, Fast & Clean, and 3D / CG Render models (the last
  one, BSRGAN, is tuned for a 3D/Blender render rather than a real photo —
  see [`Models/README.md`](Models/README.md)), plus Fast (Lanczos,
  instant) / Standard / Best (Core ML, trading tile-seam quality for speed
  via context overlap).
- **Custom presets** — name your own model+overlap combination beyond the
  built-in three; server-backed (needs a server configured).
- **iCloud presets** — the same named model+overlap combinations, but
  synced across your devices via `NSUbiquitousKeyValueStore` instead of the
  server — no server or account needed, just being signed into iCloud.
  Independent of Custom Presets above (separate storage, separate list);
  see "Known simplifications" below.
- **Batch upscale** — queue up to 20 photos, each saved to Photos as it
  finishes.
- **Cloud backup** — optionally back up a result to temporary (auto-
  expiring) server storage; browse/restore/delete from the Cloud tab.
- **History & stats** — every upscale attempt logged (technique, timing,
  success/failure), with an aggregate stats header (total, success rate,
  avg time, total megapixels produced) and swipe-to-delete/clear-all.
- **Settings backup/restore** — save your model/quality/haptics settings
  to the server and restore them later (per-device, no accounts).
- Share sheet, copy to clipboard, full-screen pinch-to-zoom preview,
  haptic feedback.
- **Share-in extension** — share a photo from Photos, Safari, Files, or any
  other app straight into PixelBoost via the system share sheet. A separate
  process from the main app (`PixelBoostShare` target), so it can't jump
  straight into the editor — it drops the image into a shared App Group
  container and the main app picks it up the next time it's brought to the
  foreground. Deliberately built on the system-provided
  `SLComposeServiceViewController` compose sheet rather than a custom
  screen; see "Known simplifications" below.

All server-backed features are optional and default off — the app is
fully functional and fully offline with no server configured.

## How it works

- `ImageTiler` splits the source photo into fixed-size, overlapping tiles
  sized to the model's input (128x128), so an arbitrarily large photo can
  go through a model that only accepts small fixed-size input. Tiles
  overlap so the model has context beyond the pixels it's actually
  responsible for; only each tile's non-overlapping "core" output is kept
  and stitched back together — the same pad-then-crop scheme Real-ESRGAN's
  own `--tile` option uses.
- `CoreMLTileUpscaler` runs each tile through the selected bundled model
  via `VNCoreMLRequest`/`VNPixelBufferObservation`.
- `LanczosUpscaler` is a same-protocol fallback using Core Image's Lanczos
  resampling — no model required, just sharper than a plain bilinear
  resize. Selected directly by the Fast quality preset.
- `UpscalerProvider` resolves/caches the right `ImageUpscaling` strategy
  for the current model+quality selection (shared across the single-image
  and batch flows via one instance injected at the app level), and
  `UpscaleRunner` runs one upscale + builds/posts its log entry — shared
  logic both `UpscalerViewModel` (single image) and `BatchUpscaleViewModel`
  (queue) call rather than each reimplementing it.

## Logging & cloud features

`server/` (`upscaler-bridge`, mirroring Lumisound's `ios-bridge` pattern) —
**live**, deployed at `https://upscaler-bridge.xenusanimations.studio`. A
FastAPI + MariaDB service backing everything server-side is optional in
the app:

- Debug logging (`upscale_history`) — every upscale attempt, for
  debugging/stats.
- Temporary image storage (`image_imports`/`image_exports`) — auto-
  expiring (default 24h, max 7 days) cloud backup for photos, with a real
  cleanup loop actually deleting expired rows, not just a documented
  intent.
- Custom presets (`custom_presets`) and settings backup
  (`device_settings`) — both per-device (no accounts).
- Model registry (`model_registry`) — server-side metadata about
  available models.

Entirely optional: set a server URL in the app's Settings tab to turn any
of this on, or leave it blank to keep the app fully offline. See
[`server/README.md`](server/README.md) for the full endpoint list and how
to run/deploy your own instance.

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) rather
than committing an `.xcodeproj` directly:

```bash
brew install xcodegen   # once
xcodegen generate
open PixelBoost.xcodeproj
```

Then build & run on a **physical device**, not the simulator — all four
bundled models are full Core ML models, and Neural Engine inference is
dramatically faster than the simulator's CPU fallback.

No extra setup for the Scripted Filter tool's Lua interpreter — it's
vendored C source under `Vendor/Lua` (see `Vendor/Lua/README.md`), wired
into the `PixelBoost` target's `sources:`/`HEADER_SEARCH_PATHS`/
`SWIFT_OBJC_BRIDGING_HEADER` in `project.yml` already, so `xcodegen
generate` picks it up like every other source file — no CocoaPods, no
Swift Package resolution, no network access needed at build time.

## Known simplifications (still a growing project, not a finished product)

- Interior tile-to-tile seams are a real, inherent limit of the
  pad-then-crop tiling scheme (`ImageTiler`) — a CNN's receptive field
  extends well past the `overlap` pixels of context each tile gets, so a
  tile right at a seam sees slightly less context than the same region
  would in a non-tiled pass. Measured as mild (real photos, general model,
  8px overlap): output near a seam differs from a non-tiled reference run
  by roughly 65% more than typical interior pixels — perceptible on close
  inspection, not usually eye-catching at normal viewing size. A true
  feathered/blended overlap (rather than pad-then-crop) would reduce this
  further but is a bigger rewrite; not done here.
- Edge tiles (the outermost `overlap` pixels of a photo's actual border,
  not interior tile seams above) get edge-replicated context via
  `UIImage.croppedEdgeReplicated(to:)`, not the plain transparent-padded
  `cropped(to:)` every other tile crop still uses. This used to be
  transparent padding — measured as a real, visible dark/smudged fringe
  hugging every photo's edge (roughly 8x the pixel divergence from a
  non-tiled reference in that border band vs. the interior on a real test
  photo), not just a discarded margin like the doc comment here used to
  claim. Edge replication cut that divergence by roughly 60% in the same
  test; it's a flat stretched-pixel approximation, not true mirroring, so
  some residual edge softness can remain.
- No disk-based caching of intermediate tiles — very large photos (many
  tiles) hold each tile's output in memory until the final stitch.
- All four bundled models' conversions were checked in PyTorch (real photo in,
  plausible sharper output, no NaNs) but the actual compiled `.mlpackage`
  files have not been run in Xcode/the simulator directly — that requires
  macOS, which wasn't available where they were converted. See
  [`Models/README.md`](Models/README.md).
- No share extension, Live Activity/background processing for long
  batches, or iCloud sync yet — a deliberate later effort, not an oversight.
- Remove Background relies entirely on Vision's own segmentation quality —
  there's no fallback or manual touch-up (refine edges, add/remove regions)
  if it misses part of the subject or includes background it shouldn't.
  Like everything else in this app, it hasn't been run on a physical
  device yet either.
- Crop is fixed-ratio-window-plus-reposition only — no corner-drag resize
  handles or free-angle straighten yet. Rotate is 90° increments only, no
  flip (the flip transforms exist in `ImageTransform` but aren't wired to
  a button yet, pending SF Symbol names worth actually trusting).
- Overlays are text-only, drag-to-reposition only — no pinch-resize or
  rotate gesture, and no dedicated sticker-art library (emoji via the
  system keyboard cover that role instead). Size/color/font/outline/shadow
  are set from a sheet, not a live on-canvas transform. The outline
  effect's on-canvas preview is an approximation (stacked offset copies,
  since SwiftUI's `Text` has no real stroke modifier) — the actual saved
  result uses a proper text-stroke attribute and looks a bit cleaner than
  the live preview.
- Object Removal ("Erase") is a classical diffusion fill (repeated,
  growing-radius blur with the unmasked pixels held fixed), not a
  generative inpainting model — there's no on-device Vision-framework
  shortcut for this the way there was for background removal, and
  blind-converting/shipping a generative model with no GPU and no
  device/simulator to check its actual output on was judged too risky to
  bet this feature on. It works well for small objects/blemishes over
  fairly uniform backgrounds; larger or heavily textured regions will come
  out smeared/blurred rather than reconstructed, since nothing here
  invents new texture.
- Face restoration ("Restore" tab) is a classical sharpen/detail boost
  blended over Vision-detected face regions, not a trained generative
  restoration model (GFPGAN/CodeFormer-class) — it can crisp up soft focus
  a little but can't reconstruct detail that genuinely isn't there, and it
  does nothing on a photo with no detectable face. Denoise is a single
  `CINoiseReduction` pass with no per-region strength control.
- Render Denoise's model conversion was sanity-checked in plain PyTorch
  against a synthetic noisy test pattern (no real render/EXR available in
  the conversion environment) rather than an actual Blender/Cycles output —
  numerically a large, coherent noise reduction (not garbage/NaNs), but not
  the same bar as "checked against a real render." It also had to use
  coremltools' legacy `neuralnetwork` backend instead of the `mlprogram`
  backend the other four models use (a missing native dependency in the
  conversion environment, not a property of the model — see
  `Models/convert/README.md`), producing a `.mlmodel` rather than a
  `.mlpackage`; functionally equivalent once Xcode compiles it, but
  untested end-to-end like everything else in this list. Fixed-strength
  only — the underlying model has no adjustable parameter, so unlike
  Restore there's no slider to back off if it's too aggressive on a given
  image.
- Adding BSRGAN as a fifth Auto-mode candidate is a real behavior change
  for every user, not just those upscaling 3D renders — Auto (and Compare
  Models) now run one more model per photo (slower), and BSRGAN's
  sharpness score could in principle win the comparison on an ordinary
  real photo too, not just a render, since the auto-pick heuristic is
  content-agnostic (a crop-sharpness test, not a render-vs-photo
  classifier). Not necessarily wrong — BSRGAN is a genuinely capable
  general upscaler, not a novelty model that only works on renders — but
  worth knowing if Auto's pick or timing changes after this update. Same
  "sanity-checked in PyTorch, not on the actual compiled `.mlmodel`, never
  run in Xcode/on a device" caveat as every other model here, and it also
  used the `neuralnetwork` conversion backend workaround (see Render
  Denoise above) — noticeably larger than the other four models (~64MB vs
  ~33MB) as a result, since that backend has no FP16 option.
- Background Replace (part of Cutout) is seven curated fills — solid
  colors, two gradients, a blurred copy of the original photo — not a
  generative model that invents a plausible new scene behind the subject.
  The blurred-original option always blurs the very first photo you
  picked, not whatever intermediate edit is currently showing, since
  there's no tracked "pre-cutout" version once other edits have chained on
  top.
- Clone Stamp composites a whole-image shift over the painted mask in one
  pass rather than sampling continuously along the drag, and there's no
  live second cursor tracking the source offset as you paint (only the
  fixed source-point marker) — both are safe simplifications since the
  offset is genuinely constant for the whole gesture, same as a real
  clone-stamp tool, just without the extra live-preview chrome.
- All eighteen tabs stay mounted simultaneously for the app's whole lifetime
  (so switching tabs never loses in-progress work) rather than being
  created/destroyed on demand — a small, deliberate memory-vs-simplicity
  tradeoff that hasn't been profiled on a real device, since none is
  available where this was built.
- The Share Extension is the riskiest piece shipped so far to have never
  run on a device or simulator: an extension's host-app lifecycle,
  App Group container access, and `SLComposeServiceViewController`'s
  compose-sheet behavior are all things Xcode can compile but can't be
  exercised without actually installing the app and triggering a real
  share sheet. It's also unsigned (this repo has no code-signing secrets
  configured — see "Building" below), and a sideloading tool re-signing
  the IPA with a different team/App Group entitlement than
  `group.com.pixelboost.shared` would silently break the hand-off (the
  extension would still "succeed" from the sharing app's point of view,
  but the photo would never reach the main app) — flag this as unverified
  if anyone hits it.
- iCloud Presets stores the entire preset list as one JSON blob under a
  single `NSUbiquitousKeyValueStore` key rather than merging per-preset —
  if two devices both save a change at nearly the same moment, whichever
  one's sync lands last simply overwrites the other's list wholesale. Same
  no-device caveat as the Share Extension: there's no second iCloud-signed
  device available here to actually watch a cross-device sync happen, so
  the multi-device behavior is unverified, only the local read/write path
  has been checked by reading through Apple's documented `KVS` semantics.
- Accent color takes effect on next launch, not live. Every tab is created
  once and stays mounted for the app's whole session (see above) — making
  a color change apply instantly everywhere would mean forcing the whole
  view tree to recreate, which would also wipe every tab's in-progress
  state. Settings still shows which color is selected immediately; only
  the actual app-wide re-tint is delayed to the next cold launch.
- Warm/Cool/Matte (Filters) and the new Vignette slider (Adjust) are all
  fixed, one-directional `CIColorMatrix`/`CIVignette`/`CIToneCurve`
  combinations, hand-picked the same way Vivid/Sepia were — not verified
  against real output on a device, same caveat as everything else in this
  app's image pipeline.
- Denoise Before Upscale runs at one fixed strength (not a slider) when
  toggled on — same one-axis-at-a-time reasoning as the rest of Restore's
  denoise control.
- Scripted Filter is capped to 900px on the longest side and a 5-second
  per-run instruction budget (see the Features entry above) — a genuine
  ceiling, not just a preview convenience like Filters/Adjust's downscaled
  previews, since the tool calls into the script once per pixel with no
  way to know ahead of time how expensive a given script's `apply` body
  is. A script that's actually fine but slow (heavy `string`/`table` work
  per pixel) can still hit the time limit and get reported as a runtime
  error rather than just running a little longer.
- `CoreMLTileUpscaler` used to hold every tile's upscaled output in an
  array until the very end, then stitch them into a final canvas — for a
  large photo (many dozens of tiles) that meant two full copies of
  roughly the same data alive at once, right at the point memory pressure
  was already highest. It now draws each tile into one shared `CGContext`
  as soon as that tile finishes, discarding the tile's own memory
  immediately after. There was also a real double-resume crash in the
  per-tile Vision request: `VNImageRequestHandler.perform(_:)` can throw
  the same error it already delivered to a request's completion handler,
  which used to resume the same `CheckedContinuation` twice — a fatal
  "SWIFT TASK CONTINUATION MISUSE" crash, and the likely actual cause
  behind "some photos crash the app while upscaling" (more likely to
  surface the longer/larger a photo's tile run is, since it only fires
  when some individual tile's inference fails). Both fixed; see the doc
  comments in `CoreMLTileUpscaler.swift`. Still not exercised on a real
  device, same caveat as the rest of this app's image pipeline.
- Investigated a report of upscaled results looking jagged/blurred/smudged,
  especially around edges. Reproduced the underlying models (real
  Real-ESRGAN weights, plain PyTorch — no Core ML runtime is available
  outside macOS/iOS, so this is the closest verification possible here)
  against real photos from the reporting user's own Photos export, tiled
  the exact way `ImageTiler`/`CoreMLTileUpscaler` do, and compared against
  a non-tiled reference pass of the same model. Found and fixed the outer-
  edge padding bug described above (a real, measured ~8x error spike right
  at every photo's border, cut by ~60% by the fix) — textually the closest
  match to "edges... all around" in the report. Also confirmed, but did
  *not* change: mild inherent interior tile-seam softness (see above), and
  that Real-ESRGAN-family models genuinely do produce blotchy/melted-
  looking texture on fine repetitive detail (sequins, glitter, some fabric
  weaves) — a known characteristic of this model family's GAN training,
  not specific to this app's conversion or integration. `compute_precision
  =ct.precision.FLOAT16` in `convert.py` (see there) remains an untested
  variable — Core ML FP16 vs FP32 differences can't be checked without
  actually running the compiled `.mlpackage` on-device, which (as
  everywhere else in this README) hasn't happened yet.
