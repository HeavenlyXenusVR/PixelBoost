"""Python port of PixelBoost's upscale pipeline, for testing model/setting
combinations without a Mac.

Mirrors, as closely as a port can:
  - CoreMLTileUpscaler.upscale(_:outputScale:maxModelInputPixels:progress:)
    — the detail budget, the RAM-tier output cap, ImageTiler's geometry,
      edge-replicated tile crops, per-tile resample into a target-size canvas
  - UpscaleRunner.run(...) — the strength blend and the sharpen pass
  - the v3.26.13-v3.26.17 behavior, for before/after comparison (`legacy=True`)

The models here are the ORIGINAL PyTorch checkpoints, not the converted Core
ML ones — the conversion is a separate step that can only be verified on
macOS. So this tests the pipeline and the model weights, not the .mlpackage.
"""
import math
import sys

import torch
import torch.nn.functional as F
from PIL import Image, ImageFilter

sys.path.insert(0, "/home/proxy/Documents/Projects/PixelBoost/Models/convert")
from rrdbnet import RRDBNet
from srvgg_arch import SRVGGNetCompact

WEIGHTS = "/home/proxy/pb-weights"
TILE_SIZE = 128

# UpscaleDetail.maxModelInputPixels
DETAIL = {"balanced": 4_000_000, "high": 8_000_000, "maximum": 16_000_000}
# CoreMLTileUpscaler.maxOutputPixels — 8GB-class iPhone tier
MAX_OUTPUT_PIXELS = 64_000_000

MODELS = {
    # name: (builder, weights file, state key, native scale)
    "generalPhoto":   (lambda: RRDBNet(num_block=23), "RealESRGAN_x4plus.pth", "params_ema", 4),
    "anime":          (lambda: RRDBNet(num_block=6), "RealESRGAN_x4plus_anime_6B.pth", "params_ema", 4),
    "portrait":       (lambda: RRDBNet(num_block=23), "RealESRNet_x4plus.pth", "params_ema", 4),
    "fastClean":      (lambda: SRVGGNetCompact(num_conv=32, upscale=4, act_type="prelu"),
                       "realesr-general-x4v3.pth", "params", 4),
    "sharp2x":        (lambda: RRDBNet(num_block=23, scale=2), "RealESRGAN_x2plus.pth", "params_ema", 2),
    "animeVideo":     (lambda: SRVGGNetCompact(num_conv=16, upscale=4, act_type="prelu"),
                       "realesr-animevideov3.pth", "params", 4),
}

_cache = {}


def load(name):
    if name in _cache:
        return _cache[name]
    build, wfile, key, native = MODELS[name]
    model = build()
    state = torch.load(f"{WEIGHTS}/{wfile}", map_location="cpu", weights_only=True)
    model.load_state_dict(state[key])
    model.eval()
    _cache[name] = (model, native)
    return model, native


def _to_tensor(img):
    t = torch.frombuffer(bytearray(img.tobytes()), dtype=torch.uint8).float() / 255.0
    return t.view(img.size[1], img.size[0], 3).permute(2, 0, 1)


def _to_image(t):
    arr = (t.clamp(0, 1) * 255).round().byte().permute(1, 2, 0).contiguous()
    return Image.frombytes("RGB", (arr.shape[1], arr.shape[0]), arr.numpy().tobytes())


def _edge_replicated_crop(src, x, y, size):
    """UIImage.croppedEdgeReplicated(to:) — a tile touching the outer border
    gets real (if flat) context in its overlap margin, not transparent edge."""
    w, h = src.shape[2], src.shape[1]
    left, top = max(0, -x), max(0, -y)
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(w, x + size), min(h, y + size)
    tile = torch.zeros(3, size, size)
    piece = src[:, y0:y1, x0:x1]
    tile[:, top:top + piece.shape[1], left:left + piece.shape[2]] = piece
    # replicate edges outward
    if top > 0:
        tile[:, :top, :] = tile[:, top:top + 1, :]
    if left > 0:
        tile[:, :, :left] = tile[:, :, left:left + 1]
    bottom = top + piece.shape[1]
    right = left + piece.shape[2]
    if bottom < size:
        tile[:, bottom:, :] = tile[:, bottom - 1:bottom, :]
    if right < size:
        tile[:, :, right:] = tile[:, :, right - 1:right]
    return tile


def upscale(img, model_name, output_scale, detail="balanced", overlap=8,
            strength=1.0, sharpen=0.0, anti_alias=0.0, legacy=False,
            batch=4, progress=None):
    """Returns (result image, stats dict)."""
    model, native = load(model_name)
    img = img.convert("RGB")
    sw, sh = img.size
    source_px = sw * sh

    if legacy:
        # v3.26.17: the OUTPUT budget (16MP, checked at the model's native
        # scale even for a 2x request) was applied by shrinking the INPUT.
        max_safe = 16_000_000
        final_px = source_px * native * native
        if final_px > max_safe:
            k = math.sqrt(max_safe / final_px)
            work = img.resize((max(1, round(sw * k)), max(1, round(sh * k))), Image.LANCZOS)
        else:
            work = img
        canvas_w, canvas_h = work.size[0] * native, work.size[1] * native
        tile_scale = native
    else:
        # Output cap limits only the canvas; it never reduces what the model sees.
        requested = source_px * output_scale * output_scale
        cap = min(1.0, math.sqrt(MAX_OUTPUT_PIXELS / max(1, requested)))
        canvas_w = max(1, round(sw * output_scale * cap))
        canvas_h = max(1, round(sh * output_scale * cap))
        budget = DETAIL[detail]
        if source_px > budget:
            k = math.sqrt(budget / source_px)
            work = img.resize((max(1, round(sw * k)), max(1, round(sh * k))), Image.LANCZOS)
        else:
            work = img
        tile_scale = None

    ww, wh = work.size
    src = _to_tensor(work)
    if legacy:
        canvas_w, canvas_h = ww * native, wh * native
    sx, sy = canvas_w / ww, canvas_h / wh

    core = TILE_SIZE - overlap * 2
    coords = [(x, y) for y in range(0, wh, core) for x in range(0, ww, core)]
    canvas = Image.new("RGB", (canvas_w, canvas_h))

    pending = []
    for i, (x, y) in enumerate(coords):
        pending.append((x, y, _edge_replicated_crop(src, x - overlap, y - overlap, TILE_SIZE)))
        if len(pending) == batch or i == len(coords) - 1:
            with torch.no_grad():
                out = model(torch.stack([p[2] for p in pending])).clamp(0, 1)
            for (tx, ty, _), o in zip(pending, out):
                cw, ch = min(core, ww - tx), min(core, wh - ty)
                dl, dt = round(tx * sx), round(ty * sy)
                dr, db = round((tx + cw) * sx), round((ty + ch) * sy)
                if dr <= dl or db <= dt:
                    continue
                tile_img = _to_image(o)
                # The kept core region inside this tile's model output.
                box = (overlap * native, overlap * native,
                       (overlap + cw) * native, (overlap + ch) * native)
                canvas.paste(tile_img.resize((dr - dl, db - dt), Image.LANCZOS, box=box), (dl, dt))
            pending = []
            if progress:
                progress(min(1.0, (i + 1) / len(coords)))

    result = canvas
    if legacy and (canvas_w, canvas_h) != (round(sw * output_scale), round(sh * output_scale)):
        # ScaledOutputUpscaler's old post-hoc resize to the requested scale.
        result = result.resize((round(sw * output_scale), round(sh * output_scale)), Image.BILINEAR)

    if strength < 1.0:
        plain = img.resize(result.size, Image.LANCZOS)
        result = Image.blend(plain, result, strength)
    if anti_alias > 0:
        result = result.filter(ImageFilter.GaussianBlur(radius=anti_alias * 2.0))
    if sharpen > 0:
        result = result.filter(ImageFilter.UnsharpMask(radius=2, percent=int(sharpen * 150), threshold=3))

    stats = {
        "model": model_name, "native": native, "scale": output_scale,
        "detail": "legacy" if legacy else detail,
        "source": f"{sw}x{sh}", "model_saw": f"{ww}x{wh}",
        "model_saw_mp": round(ww * wh / 1e6, 2),
        "output": f"{result.size[0]}x{result.size[1]}",
        "tiles": len(coords), "strength": strength,
    }
    return result, stats
