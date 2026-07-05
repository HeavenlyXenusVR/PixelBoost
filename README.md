# Upscaler

A small iOS app that upscales a photo using an on-device Core ML
super-resolution model — pick a photo, tap Upscale, save the result. No
server, no network call; everything runs on-device via the Neural
Engine/GPU through Core ML and Vision.

Ships with a plain Lanczos-resampling fallback (`LanczosUpscaler`) so the
app is fully functional even before a real model is bundled — see
[`Models/README.md`](Models/README.md) for how to add one.

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

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) rather
than committing an `.xcodeproj` directly:

```bash
brew install xcodegen   # once
xcodegen generate
open ImageUpscaler.xcodeproj
```

Then build & run on a device or simulator running iOS 16+. A physical
device is strongly recommended once a real Core ML model is bundled —
Neural Engine inference is dramatically faster than the simulator's CPU
fallback.

## Known simplifications (scaffold, not a finished product)

- Edge tiles are cropped with transparent padding rather than true
  edge-mirroring — only affects the outermost `overlap` pixels of the
  image border. See the doc comment on `UIImage.cropped(to:)` if this
  shows up as a visible artifact with a particular model.
- No disk-based caching of intermediate tiles — very large photos (many
  tiles) hold each tile's output in memory until the final stitch.
