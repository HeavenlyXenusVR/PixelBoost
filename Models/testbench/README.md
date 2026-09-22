# Test bench

A Python port of the app's upscale pipeline, so model and setting changes
can be evaluated on real images from Linux — there's no Mac here, and Core
ML can't run on one anyway.

**What this does and does not prove.** It runs the *original PyTorch
checkpoints* through a port of `CoreMLTileUpscaler`/`UpscaleRunner`. So it
tests the pipeline logic and the model weights. It does **not** test the
`.mlpackage` conversions or Core ML itself — that still needs a device.

- `pipeline.py` — the port: detail budget, RAM-tier output cap, ImageTiler
  geometry, edge-replicated tile crops, per-tile resample into a
  target-size canvas, strength blend, sharpen/anti-alias passes. Pass
  `legacy=True` for the v3.26.13–v3.26.17 behavior (output budget applied
  to the model's input) to compare against.
- `verify_tiling.py` — correctness check. These models are fully
  convolutional, so a small image can run in ONE pass with no tiling; that
  whole-image result is the reference the tiled path is measured against.
  A seam or offset bug shows up as error concentrated on tile boundaries.
- `build_sheets.py` — labeled side-by-side comparison sheets.

Setup (system Python is too new for coremltools/torch here):

```bash
uv venv --python 3.12 ~/pb-mlenv
VIRTUAL_ENV=~/pb-mlenv uv pip install torch==2.7.0 --index-url https://download.pytorch.org/whl/cpu
VIRTUAL_ENV=~/pb-mlenv uv pip install pillow
# weights: see convert/README.md for the release URLs, into ~/pb-weights
~/pb-mlenv/bin/python verify_tiling.py
```

## Results, 2026-09-22 (v3.27.0)

Tiled output vs the same crop run whole, with no tiling at all:

| config | PSNR vs untiled | error at tile seams |
|---|---|---|
| overlap 8 (Standard) | 46.94 dB | 2.0× the frame average (0.0018 — sub-visible) |
| overlap 16 (Best) | 46.96 dB | 0.86× the frame average — no seam penalty left |
| native-2x model at 2× | 41.63 dB | — |
| 4× model at 3× (every tile resampled) | 47.03 dB | exact output size, no drift |

So the rewritten geometry stitches correctly at native scale, at a
resampled scale, and with a non-4× model, and Quality: Best measurably
earns its extra time by removing the residual seam error.

Relative model cost on one 8-thread CPU, same 320×320 crop at 4× (device
numbers will be far lower on the Neural Engine, but the *ratios* hold):
General Photo 50.5s · Portrait 54.4s · Anime 16.7s · Fast & Clean 3.0s ·
Anime Video 1.6s · Native 2× at 2× 15.9s (vs General Photo's 49.0s for the
same 2× request).
