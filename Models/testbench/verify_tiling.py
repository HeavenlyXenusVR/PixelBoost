"""Correctness check for the rewritten tile/stitch geometry.

These models are fully convolutional, so a small image can be run through
in ONE pass with no tiling at all. That whole-image result is the reference:
if the tiler's plan, edge-replicated crops, per-tile resample and clipped
paste are right, the tiled result should match it closely, with differences
confined to tile borders (where a tile only has `overlap` pixels of context
instead of the whole image).

A seam bug — wrong crop origin, off-by-one dest rect, a scale mismatch —
shows up as a hard grid of high-error lines, which is what the per-row/
column error profile below would expose.
"""
import sys

import torch
import torch.nn.functional as F
from PIL import Image

import pipeline

torch.set_num_threads(8)

U = "/home/proxy/.claude/uploads/3a35ead3-8cfc-48be-82a9-e664a3871e28/"
crop = Image.open(U + "d2a514eb-image.jpg").convert("RGB").crop((560, 90, 880, 410))

model, native = pipeline.load("fastClean")
src = pipeline._to_tensor(crop).unsqueeze(0)
with torch.no_grad():
    whole = model(src).clamp(0, 1)[0]
reference = pipeline._to_image(whole)

for overlap in (8, 16):
    tiled, stats = pipeline.upscale(crop, model_name="fastClean", output_scale=4,
                                    detail="maximum", overlap=overlap)
    assert tiled.size == reference.size, (tiled.size, reference.size)
    a = pipeline._to_tensor(tiled)
    b = pipeline._to_tensor(reference)
    err = (a - b).abs().mean(0)
    mae = err.mean().item()
    psnr = 10 * torch.log10(1.0 / ((a - b) ** 2).mean()).item()

    # Per-column error, to see whether error concentrates on tile boundaries.
    col = err.mean(0)
    core = pipeline.TILE_SIZE - overlap * 2
    seam_cols = [x * core * native for x in range(1, (crop.size[0] // core) + 1)
                 if x * core * native < col.shape[0]]
    seam = sum(col[max(0, c - 2):c + 2].mean().item() for c in seam_cols) / max(1, len(seam_cols))
    interior = col.mean().item()
    print(f"overlap {overlap:>2}: MAE {mae:.5f}  PSNR {psnr:.2f} dB  "
          f"| mean err at tile seams {seam:.5f} vs overall {interior:.5f}  "
          f"(ratio {seam/max(interior,1e-9):.2f}x)  tiles={stats['tiles']}")

# 2x path too: native-2x model, 2x request, so the canvas is exactly native scale
model2, native2 = pipeline.load("sharp2x")
with torch.no_grad():
    whole2 = model2(src).clamp(0, 1)[0]
ref2 = pipeline._to_image(whole2)
tiled2, st2 = pipeline.upscale(crop, model_name="sharp2x", output_scale=2, detail="maximum")
a, b = pipeline._to_tensor(tiled2), pipeline._to_tensor(ref2)
print(f"native-2x @2x: size {tiled2.size} vs reference {ref2.size} | "
      f"PSNR {10*torch.log10(1.0/((a-b)**2).mean()).item():.2f} dB")

# And a non-native ratio (4x model asked for 3x), where every tile is resampled
tiled3, st3 = pipeline.upscale(crop, model_name="fastClean", output_scale=3, detail="maximum")
ref3 = reference.resize(tiled3.size, Image.LANCZOS)
a, b = pipeline._to_tensor(tiled3), pipeline._to_tensor(ref3)
print(f"4x model @3x: size {tiled3.size} (expect {crop.size[0]*3}x{crop.size[1]*3}) | "
      f"PSNR vs downsampled-whole {10*torch.log10(1.0/((a-b)**2).mean()).item():.2f} dB")
