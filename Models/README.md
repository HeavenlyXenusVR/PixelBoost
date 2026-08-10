# Models

Four Core ML models are bundled, picked automatically via `UpscalerProvider`
(Auto mode) or manually in the model picker — all
[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)-family conversions,
BSD-3-Clause. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the
license text and [`convert/`](convert/) for the conversion pipeline (one
script, two supported architectures).

| File | Source | Architecture | Best for |
|---|---|---|---|
| `RealESRGAN.mlpackage` | `RealESRGAN_x4plus.pth` | RRDBNet, 23 blocks | General photos (default) |
| `RealESRGANAnime.mlpackage` | `RealESRGAN_x4plus_anime_6B.pth` | RRDBNet, 6 blocks (smaller/faster) | Anime/illustration art |
| `RealESRNet.mlpackage` | `RealESRNet_x4plus.pth` | RRDBNet, 23 blocks | Portraits — same architecture/data as x4plus but trained with only L1 loss (no GAN), so it's smoother and less prone to over-sharpened/ringing artifacts on skin |
| `RealESRGeneralV3.mlpackage` | `realesr-general-x4v3.pth` | SRVGGNetCompact, 32 conv layers | Everyday quick default — much smaller/faster than any RRDBNet model, cleaner result on typical real-world photos |

`Auto` (see `UpscalerProvider.autoSelectModel`) tests every bundled model
above against a crop of the photo and keeps whichever scores sharper,
rather than picking one of these by fixed default.

A fifth model, `OIDNRenderDenoise.mlmodel`, backs the separate **Render
Denoise** tab (not part of Upscale/Auto above — it denoises in place, it
doesn't super-resolve):

| File | Source | Architecture | Best for |
|---|---|---|---|
| `OIDNRenderDenoise.mlmodel` | `rt_ldr_small.tza` (Intel Open Image Denoise) | Small U-Net (4 pool/upsample stages, 32ch encoder) | Cleaning up noise from a 3D/Blender render (Cycles, Eevee, any path tracer) — a different noise character than a photo's sensor grain, which is what Restore's `CINoiseReduction` slider targets instead |

Converted with [`convert_oidn.py`](convert/convert_oidn.py) from
`rt_ldr_small.tza` (Apache-2.0, [RenderKit/oidn-weights](https://github.com/RenderKit/oidn-weights))
— the same beauty-only (no albedo/normal AOVs), fast/"small" filter variant
Blender's Cycles Denoise node itself uses, reimplemented in PyTorch
(`oidn_unet.py`) since Intel only ships pretrained weights in their own
`.tza` binary format, not as a PyTorch/ONNX checkpoint — see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the license and
attribution and "Swapping in a different model" below for **the one
real difference from the other four**: this conversion had to use
coremltools' legacy `neuralnetwork` backend (producing a flat `.mlmodel`,
not an `.mlpackage`) rather than the modern `mlprogram`/ML Program backend
the other four use, because the machine this was converted on lacked the
compiled `libmilstoragepython` native extension `mlprogram` needs to
externalize weights into a `.mlpackage`'s separate weight blob — a Linux/
Python-3.14 environment limitation, not a property of the model itself.
Functionally equivalent (Xcode compiles either into the same `.mlmodelc`),
just worth knowing if a future re-convert on a machine with a full
coremltools install ever swaps it back to `.mlpackage`.
Sanity-checked the same way as the other four: ran the un-converted PyTorch
model (weights loaded straight from the `.tza`) against a synthetic noisy
test image (no real render/EXR available in the conversion environment) —
mean-squared error against the clean reference dropped ~7.6x and
high-frequency noise energy dropped ~25x after denoising, no NaNs. Like
every other model here, **the actual compiled `.mlmodel` has not been run
in Xcode/on-device** — that requires macOS, unavailable where this was
converted.

**Not verified end-to-end.** All four conversions (`torch.jit.trace` →
`coremltools.convert`) produce a `.mlpackage` with the right input/output
shapes, and the underlying PyTorch model + weights were checked separately
for each (ran the un-converted model on a real crop, got a plausible
sharper/higher-res result, no NaNs) — but none of the compiled Core ML
models have been run on-device or in Xcode's simulator by this change,
since that requires macOS.

**Corruption investigation — two separate bugs found, chased down to
compositing code:**

1. The in-app compare/zoom preview handing a full-resolution result (a 4x
   upscale of a modern phone photo easily clears 50MP) straight to a live
   SwiftUI `Image` tears into repeating horizontal bands on real hardware
   — a display-only artifact, fixed by `UIImage.downsampledForDisplay` in
   `PixelBoost/Sources/Services/UIImage+Display.swift`. Real, but **not
   the whole story**: a saved/exported file (watermark already baked in
   by `Watermark.apply`, so genuinely post-pipeline output, not a
   preview) sent from a real iPhone 13 showed the same torn-band
   corruption — the actual pixel data written to Photos was corrupted
   too, independent of #1.
2. For #1's leftover corruption: tried excluding the Neural Engine
   (`.cpuAndGPU`, v3.22.1), then excluding GPU too (`.cpuOnly`, v3.22.3),
   on the theory this was a compute-backend miscompilation. A real-device
   A/B of the same photo on both builds produced **pixel-identical**
   corrupted output — proof the bug is fully deterministic and has
   nothing to do with which backend runs the model. That pointed at
   `CoreMLTileUpscaler`'s own tile-stitching code, specifically the
   version (introduced alongside the Pixel Art/Lua tools, never verified
   on hardware) that drew each tile directly into one shared `CGContext`
   with a hand-rolled `translateBy`/`scaleBy` coordinate flip instead of
   the original `UIGraphicsImageRenderer`-based stitch. Reverted back to
   the `UIGraphicsImageRenderer` approach — it was correct before that
   rewrite and never itself implicated by any report. Needs on-device
   confirmation; if corruption somehow persists even after this, the
   conversion pipeline (`convert/`) is the next thing to check, not
   anything runtime/compositing-related, since both are now ruled out.

**Performance:** the general model (23 RRDB blocks) is the highest-quality
but heaviest config — test on a physical device, not the simulator. The
anime model (6 blocks) is noticeably smaller (~9MB vs ~33MB). RealESRNet is
the same size/shape as the general model (same architecture) but should
look different, not faster. RealESRGeneralV3 is the smallest and fastest of
the four (~2.5MB) — SRVGGNetCompact has no residual dense blocks at all.
Neural Engine inference should be reasonably fast either way; CPU-only
fallback will be slow per 128x128 tile, multiplied by however many tiles a
full photo needs.

## Swapping in a different model

Change `UpscaleModelChoice` in `UpscalerProvider.swift` to match (add a
case, or repoint an existing one's `modelName`). Two ways to get another
model:

1. **Find one already converted** — search for "coreml" alongside the
   model name; check its license before shipping it.
2. **Convert one yourself** — see [`convert/`](convert/); `convert.py`
   takes `--arch {rrdbnet,srvgg}` plus `--weights`/`--num-block` (rrdbnet)
   or `--num-conv` (srvgg) /`--out`/`--description`, so it covers any
   RRDBNet- or SRVGGNetCompact-architecture Real-ESRGAN checkpoint without
   modification. For a genuinely different architecture, adapt it: trace
   the PyTorch model at a fixed input size with `torch.jit.trace`, then
   `coremltools.convert(..., inputs=[ct.ImageType(...)],
   outputs=[ct.ImageType(...)])` so the compiled model takes/returns
   `CVPixelBuffer`s directly — that's what lets `CoreMLTileUpscaler` use
   `VNCoreMLRequest`/`VNPixelBufferObservation` without manual pixel-format
   handling. Bake any output denormalization (e.g. clamp + scale back to
   0-255) into the traced graph itself, since output `ImageType` doesn't
   apply scale/bias the way input `ImageType` does.

## Matching `CoreMLTileUpscaler.Config`

| Config field | Must equal |
|---|---|
| `tileSize` | The model's fixed input width/height, in pixels (128 for all four bundled models) |
| `scaleFactor` | The model's output size ÷ input size (4 for all four bundled models) |
| `overlap` | Your choice — context pixels fed to the model beyond what's kept; 8-16 is reasonable for a 128px tile (see `UpscaleQuality`'s Standard/Best presets) |
