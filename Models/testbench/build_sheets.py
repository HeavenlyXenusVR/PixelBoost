"""Builds labeled comparison sheets from the test outputs."""
import json
import os

from PIL import Image, ImageDraw, ImageFont

OUT = "out"
SHEETS = "sheets"
os.makedirs(SHEETS, exist_ok=True)

FONT_PATHS = [
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/noto/NotoSans-Bold.ttf",
]


def font(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


BG = (18, 18, 22)
INK = (245, 245, 250)
DIM = (165, 165, 180)


def panel(img, size, center_frac=None):
    """Center-crop to a square view of `size` px, optionally zooming into a
    fraction of the image first so every panel shows the same region."""
    w, h = img.size
    if center_frac:
        cw, ch = int(w * center_frac), int(h * center_frac)
        img = img.crop(((w - cw) // 2, (h - ch) // 2, (w - cw) // 2 + cw, (h - ch) // 2 + ch))
    w, h = img.size
    side = min(w, h)
    img = img.crop(((w - side) // 2, (h - side) // 2, (w - side) // 2 + side, (h - side) // 2 + side))
    return img.resize((size, size), Image.LANCZOS if side > size else Image.NEAREST)


def sheet(path, title, subtitle, items, cols, cell=560, center_frac=None):
    """items: list of (image path, label, sublabel)"""
    rows = (len(items) + cols - 1) // cols
    pad, head, cap = 18, 120, 58
    W = cols * cell + pad * (cols + 1)
    H = head + rows * (cell + cap) + pad * (rows + 1)
    canvas = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(canvas)
    d.text((pad + 4, 26), title, font=font(38), fill=INK)
    d.text((pad + 4, 74), subtitle, font=font(21), fill=DIM)

    for i, (p, label, sub) in enumerate(items):
        r, c = divmod(i, cols)
        x = pad + c * (cell + pad)
        y = head + pad + r * (cell + cap + pad)
        canvas.paste(panel(Image.open(p), cell, center_frac), (x, y))
        d.rectangle([x, y, x + cell - 1, y + cell - 1], outline=(70, 70, 82))
        d.text((x + 2, y + cell + 8), label, font=font(25), fill=INK)
        d.text((x + 2, y + cell + 36), sub, font=font(18), fill=DIM)
    canvas.save(path)
    print("wrote", path, canvas.size)


man = {m["tag"]: m for m in json.load(open(f"{OUT}/manifest.json"))}


def sub(tag):
    m = man.get(tag, {})
    s = m.get("seconds", 0)
    return f"model saw {m.get('model_saw','-')}  ·  {s}s on this CPU" if s else f"model saw {m.get('model_saw','-')}"


# Sheet 1 — models on a face
sheet(f"{SHEETS}/1_models_face.png", "Models — 4× on a face crop",
      "Same 320×320 source region, Detail: Maximum, Strength 100%. Zoomed to the eyes so differences are visible.",
      [(f"{OUT}/face_lanczos.png", "No model (plain resize)", "what Quality: Fast does"),
       (f"{OUT}/face_generalPhoto.png", "General Photo", sub("face_generalPhoto")),
       (f"{OUT}/face_portrait.png", "Portrait (RealESRNet)", sub("face_portrait")),
       (f"{OUT}/face_anime.png", "Anime / Illustration", sub("face_anime")),
       (f"{OUT}/face_fastClean.png", "Fast & Clean", sub("face_fastClean")),
       (f"{OUT}/face_animeVideo.png", "Anime Video (NEW)", sub("face_animeVideo"))],
      cols=3, center_frac=0.45)

# Sheet 2 — models on fabric/text
sheet(f"{SHEETS}/2_models_text.png", "Models — 4× on fabric, text and hard edges",
      "The RUMI patch and zipper teeth: where over-sharpening, ringing and smearing show up worst.",
      [(f"{OUT}/fabric_lanczos.png", "No model (plain resize)", "what Quality: Fast does"),
       (f"{OUT}/fabric_generalPhoto.png", "General Photo", sub("fabric_generalPhoto")),
       (f"{OUT}/fabric_portrait.png", "Portrait (RealESRNet)", sub("fabric_portrait")),
       (f"{OUT}/fabric_anime.png", "Anime / Illustration", sub("fabric_anime")),
       (f"{OUT}/fabric_fastClean.png", "Fast & Clean", sub("fabric_fastClean")),
       (f"{OUT}/fabric_animeVideo.png", "Anime Video (NEW)", sub("fabric_animeVideo"))],
      cols=3, center_frac=0.5)

# Sheet 3 — the new native 2x model at 2x output
sheet(f"{SHEETS}/3_native_2x.png", "New “Native 2×” model vs 4× models asked for 2×",
      "Output Scale 2×. The 4× models analyze at 4× and resample down; Native 2× produces 2× directly.",
      [(f"{OUT}/face2x_sharp2x.png", "Native 2× (NEW)", sub("face2x_sharp2x")),
       (f"{OUT}/face2x_generalPhoto.png", "General Photo at 2×", sub("face2x_generalPhoto")),
       (f"{OUT}/face2x_fastClean.png", "Fast & Clean at 2×", sub("face2x_fastClean"))],
      cols=3, center_frac=0.45)

# Sheet 4 — the regression fix, full image
sheet(f"{SHEETS}/4_before_after.png", "The v3.26.17 bug vs the v3.26.18 fix",
      "Full 1086x1448 image, Fast & Clean model, same 4x request. Only the pipeline differs. This source is 1.57MP, under even the Balanced budget, so Balanced and Maximum are identical here - on a 12MP phone photo the gap is far bigger.",
      [(f"{OUT}/full_legacy_4x.png", "v3.26.17 (broken)", sub("full_legacy_4x")),
       (f"{OUT}/full_new_4x_balanced.png", "v3.26.18 (any Detail)", sub("full_new_4x_balanced")),
       (f"{OUT}/face_overlap16.png", "Quality: Best (overlap 16)", sub("face_overlap16"))],
      cols=3, center_frac=0.22)

sheet(f"{SHEETS}/5_before_after_2x.png", "Same bug at 2× output — where it was worst",
      "At 2× the old build shrank the photo to ~1MP, ran the model, then stretched the result back up.",
      [(f"{OUT}/full_legacy_2x.png", "v3.26.17 (broken)", sub("full_legacy_2x")),
       (f"{OUT}/full_new_2x.png", "v3.26.18 · Maximum", sub("full_new_2x"))],
      cols=2, cell=700, center_frac=0.22)
