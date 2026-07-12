# PixelBoost

A small iOS app for upscaling and editing photos, fully on-device (Neural
Engine/GPU via Core ML and Vision, no network call required) — started as
a pure super-resolution app and is growing into a broader photo editor
(background removal now, more editing tools planned). There's a separate,
optional server (`server/`) for debug logging, temporary cloud backup, and
custom presets — see "Logging & cloud features" below.

**Requires iOS 17** — Remove Background (Cutout) uses Vision's
`VNGenerateForegroundInstanceMaskRequest`, which iOS 16 doesn't have.

Ships with four real converted models (all BSD-3-Clause, see
[`Models/README.md`](Models/README.md)) — Real-ESRGAN's general-photo
`x4plus`, anime/illustration-optimized `anime_6B`, low-artifact portrait
`RealESRNet_x4plus`, and the fast/lightweight `realesr-general-x4v3` — plus
a plain Lanczos-resampling fallback (`LanczosUpscaler`) so the app still
works if a model is ever missing/swapped out. An Auto mode runs every
bundled model on the *full* photo and shows every result so you can
compare and pick the one you like, rather than a heuristic quietly
deciding for you — see "Compare Models" below.

---

## Features

- **Bottom tab bar** — every screen (Upscale plus all seven editing tools,
  plus Batch/Cloud/History/Settings) is its own tab in a horizontally
  scrollable bar along the bottom, instead of tools being buried behind a
  menu or a top toolbar. There are twelve tabs, more than the ~5 a native
  iOS tab bar shows before collapsing the rest into an auto-generated
  "More" list, so this is a custom bar rather than `TabView`. Every tab
  stays mounted the whole time you have the app open, so switching away
  and back never loses whatever you were in the middle of (a crop
  selection, paint strokes, slider positions):
  - **Cutout** — cuts the main subject(s) out of a photo with a
    transparent background, using Vision's on-device subject-lifting API
    (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+) — the same
    technology behind Photos' own "Lift Subject." No custom model needed.
  - **Enhance** — one-tap automatic exposure/color correction via Core
    Image's built-in `autoAdjustmentFilters` (the same auto-analysis API
    behind Snapseed's "Tune Image" auto button and Photoshop Express's
    "Auto Enhance") — no manual sliders, no custom model.
  - **Adjust** — brightness/contrast/saturation/exposure, live preview.
  - **Crop & Rotate** — 90° rotate plus fixed-ratio crop (Free/1:1/4:5/
    5:4/16:9/9:16); drag the crop window to reposition it.
  - **Filters** — ten one-tap looks (Vivid, Mono, Noir, Silvertone,
    Chrome, Process, Transfer, Instant, Fade, Sepia) built from Core
    Image's built-in photo-effect filters, picked from a strip of
    thumbnails rendered against your actual photo, not generic swatches.
  - **Overlays** — add text (and, via the system keyboard's own emoji
    key, "stickers") on top of a photo; drag to reposition, tap to edit
    color/size or delete.
  - **Erase** (object removal) — paint over something to erase it; the
    marked area is filled in with a diffusion-based fill that pulls
    color inward from the surrounding pixels — not a generative model,
    see "Known simplifications" below.

  Each editing tab has an **Apply** button instead of a Done/Cancel —
  applying bakes the edit onto the shared result and resets that tab back
  to a blank slate (fresh sliders, empty overlay layer, cleared brush
  strokes), but you stay right there; there's no dismiss step, you just
  tap another tab whenever you want to move on. Cutout is the one
  exception — it's a single unattended action, not something with
  in-place controls, so it just runs and updates in place. All seven chain
  onto whichever result is currently showing (crop the upscaled photo,
  filter a cutout, etc.) rather than always reaching back to the original
  photo.
- **Compare Models** — with Auto selected, Upscale runs the whole photo
  through every bundled model and shows every result in a tappable,
  full-screen-viewable grid; pick whichever looks best, or save them all.
- **2x/3x/4x output scale** — every model natively super-resolves at 4x
  (that's fixed by the architecture), then the result is resized down to
  your chosen final size — so 2x/3x still benefit from the model's full
  detail instead of skipping analysis to hit a smaller ratio directly.
- **Before/after comparison slider** — drag to reveal, right on the main
  screen once a photo's upscaled.
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
  Illustration, Portrait, and Fast & Clean models, plus Fast (Lanczos,
  instant) / Standard / Best (Core ML, trading tile-seam quality for speed
  via context overlap).
- **Custom presets** — name your own model+overlap combination beyond the
  built-in three.
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

## Known simplifications (still a growing project, not a finished product)

- Edge tiles are cropped with transparent padding rather than true
  edge-mirroring — only affects the outermost `overlap` pixels of the
  image border. See the doc comment on `UIImage.cropped(to:)` if this
  shows up as a visible artifact with a particular model.
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
  system keyboard cover that role instead). Size/color are set from a
  sheet, not a live on-canvas transform.
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
- All twelve tabs stay mounted simultaneously for the app's whole lifetime
  (so switching tabs never loses in-progress work) rather than being
  created/destroyed on demand — a small, deliberate memory-vs-simplicity
  tradeoff that hasn't been profiled on a real device, since none is
  available where this was built.
