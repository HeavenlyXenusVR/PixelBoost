# Upscaler

A small iOS app that upscales a photo using an on-device Core ML
super-resolution model — pick a photo, tap Upscale, save the result. The
upscale itself is fully on-device (Neural Engine/GPU via Core ML and
Vision) and needs no network call; there's a separate, optional server
(`server/`) purely for debug logging — see "Logging" below.

Ships with a real converted model — Real-ESRGAN's `x4plus` (BSD-3-Clause,
see [`Models/README.md`](Models/README.md)) — plus a plain
Lanczos-resampling fallback (`LanczosUpscaler`) so the app still works if a
model is ever missing/swapped out.

---

## How it works

- `ImageTiler` splits the source photo into fixed-size, overlapping tiles
  sized to the model's input (default 128x128), so an arbitrarily large
  photo can go through a model that only accepts small fixed-size input.
  Tiles overlap so the model has context beyond the pixels it's actually
  responsible for; only each tile's non-overlapping "core" output is kept
  and stitched back together — the same pad-then-crop scheme Real-ESRGAN's
  own `--tile` option uses.
- `CoreMLTileUpscaler` runs each tile through the bundled model via
  `VNCoreMLRequest`/`VNPixelBufferObservation`.
- `LanczosUpscaler` is a same-protocol fallback using Core Image's Lanczos
  resampling — no model required, just sharper than a plain bilinear
  resize.
- `UpscalerViewModel` picks whichever upscaler is available (Core ML if a
  model is bundled, Lanczos otherwise) and drives the picker → upscale →
  save-to-Photos flow.

## Logging

`server/` is a small FastAPI + MariaDB service (`upscaler-bridge`,
mirroring Lumisound's `ios-bridge` pattern) that records every upscale
attempt — source image size, technique/model used, tile config, timing,
success/failure — for debugging. It's entirely optional: set a server URL
in the app's Settings tab to turn logging on, or leave it blank (the
default) to keep the app fully offline. See [`server/README.md`](server/README.md)
for how to run/deploy it — verified working locally against a throwaway
MariaDB, but not deployed anywhere yet.

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) rather
than committing an `.xcodeproj` directly:

```bash
brew install xcodegen   # once
xcodegen generate
open ImageUpscaler.xcodeproj
```

Then build & run on a **physical device**, not the simulator — the bundled
model is the full-size Real-ESRGAN config, and Neural Engine inference is
dramatically faster than the simulator's CPU fallback.

## Known simplifications (scaffold, not a finished product)

- Edge tiles are cropped with transparent padding rather than true
  edge-mirroring — only affects the outermost `overlap` pixels of the
  image border. See the doc comment on `UIImage.cropped(to:)` if this
  shows up as a visible artifact with a particular model.
- No disk-based caching of intermediate tiles — very large photos (many
  tiles) hold each tile's output in memory until the final stitch.
- The bundled model's conversion was checked in PyTorch (real photo in,
  plausible sharper output, no NaNs) but the actual compiled `.mlpackage`
  has not been run — that requires Xcode/macOS, which wasn't available
  where it was converted. See [`Models/README.md`](Models/README.md).
