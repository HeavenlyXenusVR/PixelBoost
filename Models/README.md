# Models

`RealESRGAN.mlpackage` is bundled and picked up automatically by
`CoreMLTileUpscaler` — no setup needed. It's a Core ML conversion of
[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)'s `x4plus` model
(general-purpose photo 4x upscaling, BSD-3-Clause). See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the license text and
[`convert/`](convert/) for the conversion script.

**Not verified end-to-end.** The conversion (`torch.jit.trace` →
`coremltools.convert`) was run and produces a `.mlpackage` with the right
input/output shapes, and the underlying PyTorch model + weights were checked
separately (ran the un-converted model on a real photo, got a plausible
sharper/higher-res result, no NaNs) — but the actual compiled Core ML model
has not been run on-device or in Xcode's simulator, since that requires
macOS. Build and try it on a real photo before trusting the output; if
something looks wrong, that's the first place to look.

**Performance:** `num_block=23` (the full/"plus" variant, not the smaller
anime model) is the highest-quality but heaviest Real-ESRGAN config — test
on a physical device, not the simulator. Neural Engine inference should be
reasonably fast; CPU-only fallback will be slow per 128x128 tile,
multiplied by however many tiles a full photo needs.

## Swapping in a different model

Change `modelName`/`Config` in `CoreMLTileUpscaler.swift` to match. Two
ways to get another model:

1. **Find one already converted** — search for "coreml" alongside the
   model name; check its license before shipping it.
2. **Convert one yourself** — see [`convert/`](convert/) for a working
   example (Real-ESRGAN specifically), or adapt it: trace the PyTorch model
   at a fixed input size with `torch.jit.trace`, then
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
| `tileSize` | The model's fixed input width/height, in pixels (128 for the bundled model) |
| `scaleFactor` | The model's output size ÷ input size (4 for the bundled model) |
| `overlap` | Your choice — context pixels fed to the model beyond what's kept; 8-16 is reasonable for a 128px tile |
