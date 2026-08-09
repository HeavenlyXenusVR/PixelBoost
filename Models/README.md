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

**Not verified end-to-end.** All four conversions (`torch.jit.trace` →
`coremltools.convert`) produce a `.mlpackage` with the right input/output
shapes, and the underlying PyTorch model + weights were checked separately
for each (ran the un-converted model on a real crop, got a plausible
sharper/higher-res result, no NaNs) — but none of the compiled Core ML
models have been run on-device or in Xcode's simulator by this change,
since that requires macOS.

**Ongoing corruption investigation — two separate bugs found so far, at
least one still unresolved:**

1. The in-app compare/zoom preview handing a full-resolution result (a 4x
   upscale of a modern phone photo easily clears 50MP) straight to a live
   SwiftUI `Image` tears into repeating horizontal bands on real hardware
   — a display-only artifact, fixed by `UIImage.downsampledForDisplay` in
   `PixelBoost/Sources/Services/UIImage+Display.swift`. Confirmed this was
   real but **not the whole story**: a saved/exported file (watermark
   already baked in by `Watermark.apply`, so this is genuinely
   post-pipeline output, not a preview) sent from a real iPhone 13 showed
   the same torn-band corruption, meaning the actual pixel data written to
   Photos can be corrupted too, independent of how it's later displayed.
2. `MLModelConfiguration.computeUnits = .cpuAndGPU` (Neural Engine
   excluded, GPU/Metal still allowed) was tried first, on the theory this
   was an ANE miscompilation. The corrupted-file report above showed up
   even so — so ANE was never actually the (sole) cause, only ruled out on
   its own; GPU/Metal execution of this converted graph was never actually
   isolated. Currently forcing `.cpuOnly` (see `CoreMLTileUpscaler.init`)
   to finally test that. This is a diagnostic, not a shipped fix: pure-CPU
   inference is real-time-hostile for a multi-dozen-tile photo, so if this
   turns out to be the actual cause, the long-term fix needs to be a
   specific GPU-path workaround, not permanently disabling GPU/ANE.
   If corruption persists even under `.cpuOnly`, the compute backend isn't
   the cause at all — look at the conversion pipeline (`convert/`) itself
   next, not the runtime.

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
