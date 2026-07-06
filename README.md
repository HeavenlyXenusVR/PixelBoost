# PixelBoost

A small iOS app that upscales a photo using an on-device Core ML
super-resolution model — pick a photo, tap Upscale, save the result. The
upscale itself is fully on-device (Neural Engine/GPU via Core ML and
Vision) and needs no network call; there's a separate, optional server
(`server/`) for debug logging, temporary cloud backup, and custom presets —
see "Logging & cloud features" below.

Ships with two real converted models — Real-ESRGAN's general-photo
`x4plus` and anime/illustration-optimized `anime_6B` (both BSD-3-Clause,
see [`Models/README.md`](Models/README.md)), switchable in Settings — plus
a plain Lanczos-resampling fallback (`LanczosUpscaler`) so the app still
works if a model is ever missing/swapped out.

---

## Features

- **Before/after comparison slider** — drag to reveal, right on the main
  screen once a photo's upscaled.
- **Model & quality picker** (Settings) — General Photo / Anime
  illustration models, and Fast (Lanczos, instant) / Standard / Best
  (Core ML, trading tile-seam quality for speed via context overlap).
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

Then build & run on a **physical device**, not the simulator — both
bundled models are full Core ML models, and Neural Engine inference is
dramatically faster than the simulator's CPU fallback.

## Known simplifications (still a growing project, not a finished product)

- Edge tiles are cropped with transparent padding rather than true
  edge-mirroring — only affects the outermost `overlap` pixels of the
  image border. See the doc comment on `UIImage.cropped(to:)` if this
  shows up as a visible artifact with a particular model.
- No disk-based caching of intermediate tiles — very large photos (many
  tiles) hold each tile's output in memory until the final stitch.
- Both bundled models' conversions were checked in PyTorch (real photo in,
  plausible sharper output, no NaNs) but the actual compiled `.mlpackage`
  files have not been run in Xcode/the simulator directly — that requires
  macOS, which wasn't available where they were converted. See
  [`Models/README.md`](Models/README.md).
- No share extension, Live Activity/background processing for long
  batches, or iCloud sync yet — a deliberate later effort, not an oversight.
