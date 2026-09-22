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

## Edge-energy calibration, 2026-09-22

`ImageStatistics.edgeEnergy` and `UpscalerProvider.sharpnessScore` are the
same measurement — mean **absolute** 3x3 Laplacian over a grayscale copy,
0...255 — and `edge_stats.py` reproduces it here.

The absolute value is the whole point. A Laplacian kernel sums to zero, so
the *signed* mean of its response is ~0 for any image; measured across
every test image it came out at ±0.0000. The previous implementation
averaged the signed response through Core Image, which measures nothing
unless some intermediate clamps the negative lobes away — and whether that
happens depends on CIContext's working format, not on the photo.

Reference values (256px center crop, the region Auto actually measures):

| source | edge energy |
|---|---|
| dark concert poster | 1.3 |
| ordinary photo | 4.2 |
| 3D-render screenshot (trio closeup) | 9.0 |
| 3D-render screenshot (trio standing) | 11.7 |
| 3-panel line art | 13.1 |
| game keyart | 14.1 |
| dense HUNTRX poster | 26.2 |

Model outputs, 320px crop at 4x:

| model | face | fabric/text |
|---|---|---|
| plain resize (no model) | 1.27 | 1.48 |
| General Photo | 4.01 | 4.26 |
| Anime / Illustration | 3.71 | 4.44 |
| Fast & Clean | 3.45 | 4.28 |
| Anime Video | 3.33 | 3.87 |
| Portrait | 2.18 | 2.86 |

Two things follow. Scores land in roughly 1-5, so Auto's old fixed "+10 /
+12 / +15" content bonuses weren't breaking ties, they were overruling the
measurement entirely — they're now fractions of the candidate's own score.
And Anime Video sits within ~15% of the heavier anime model while costing
about a tenth as much, which is why it takes the larger line-art nudge.

These thresholds come from a handful of images on one Linux box. Auto now
logs `auto_model_pick` with the measured stats and every candidate's score,
so they can be re-calibrated from real photos on real devices.
