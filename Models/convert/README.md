# Converting Real-ESRGAN to Core ML

Reproduces the four Real-ESRGAN `../*.mlpackage` files (BSRGAN — a fifth
`convert.py` architecture — and the separate Render Denoise/OIDN model each
have their own section further below). Requires Python 3.11
(coremltools 9.0 at time of writing doesn't yet support 3.13) and works on
Linux or macOS — only the final `.mlpackage` → `.mlmodelc` compile step
needs Xcode. Tested with `torch==2.7.0` specifically (coremltools 9.0's
last-verified version at time of writing); a newer `torch` will still
convert but prints a compatibility warning.

```bash
python3.11 -m venv venv
source venv/bin/activate
pip install coremltools
pip install "torch==2.7.0" --index-url https://download.pytorch.org/whl/cpu

# Weights from the official releases (BSD-3-Clause, see ../THIRD_PARTY_NOTICES.md)
curl -sL https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth -o RealESRGAN_x4plus.pth
curl -sL https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth -o RealESRGAN_x4plus_anime_6B.pth
curl -sL https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.1/RealESRNet_x4plus.pth -o RealESRNet_x4plus.pth
curl -sL https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth -o realesr-general-x4v3.pth

# General photo model (23 RRDB blocks — the default args)
python3 convert.py --weights RealESRGAN_x4plus.pth --num-block 23 \
    --out RealESRGAN.mlpackage --description "Real-ESRGAN x4plus"

# Anime/illustration model (6 blocks — smaller & faster)
python3 convert.py --weights RealESRGAN_x4plus_anime_6B.pth --num-block 6 \
    --out RealESRGANAnime.mlpackage --description "Real-ESRGAN x4plus anime_6B"

# Portrait model — same RRDBNet architecture as x4plus, trained without a
# GAN loss, so it lands smoother/lower-artifact rather than sharper
python3 convert.py --weights RealESRNet_x4plus.pth --num-block 23 \
    --out RealESRNet.mlpackage --description "Real-ESRGAN RealESRNet_x4plus"

# Fast & Clean model — different architecture (SRVGGNetCompact, --arch srvgg)
python3 convert.py --weights realesr-general-x4v3.pth --arch srvgg --num-conv 32 \
    --out RealESRGeneralV3.mlpackage --description "Real-ESRGAN realesr-general-x4v3"
```

`rrdbnet.py` is the RRDBNet architecture (the `x4plus`/`anime_6B`/
`RealESRNet_x4plus` models) copied out of `xinntao/BasicSR`'s
`basicsr/archs/rrdbnet_arch.py`, with the `basicsr` package dependency
stripped out — the full `basicsr`/`realesrgan` pip packages pull in
`torchvision.transforms.functional_tensor`, which was removed in current
torchvision and breaks on import. Since we only need inference with
pretrained weights (not training), the only real dependency was
`make_layer`, which is a few lines and easy to inline; the
`default_init_weights` and `pixel_unshuffle` helpers the original file
imports are either irrelevant at inference time or dead code for the x4plus
(scale=4) configuration specifically.

`srvgg_arch.py` is the SRVGGNetCompact architecture (the
`realesr-general-x4v3` model) copied out of `xinntao/Real-ESRGAN`'s
`realesrgan/archs/srvgg_arch.py`, same treatment — the `ARCH_REGISTRY`
decorator/import is the only thing stripped, since it's only used for
name-based lookup during training. `convert.py` picks the checkpoint's
`params_ema` key if present (RRDBNet checkpoints) or falls back to `params`
(SRVGGNetCompact checkpoints have no EMA weights).

`convert.py` wraps the raw model to bake Real-ESRGAN's pixel-range
convention into the graph: input `ImageType(scale=1/255)` divides the
incoming 0-255 image down to the `[0,1]` range the model expects, and the
wrapper clamps + multiplies the model's output back up to `[0,255]` before
it's declared as an output `ImageType` — so the compiled model takes and
returns plain images with no manual normalization needed on the Swift side.

## Converting BSRGAN (the "3D / CG Render" upscale model)

Reproduces `../BSRGAN.mlmodel` — same `convert.py` as the four Real-ESRGAN
models above, via its `--arch bsrgan` option, since BSRGAN is the same
RRDBNet math (just an older layer-naming convention checkpoint — see
`bsrgan_arch.py`'s doc comment):

```bash
# Weights from the official release (Apache-2.0, see ../THIRD_PARTY_NOTICES.md)
curl -sL https://github.com/cszn/KAIR/releases/download/v1.0/BSRGAN.pth -o BSRGAN.pth

python3 convert.py --weights BSRGAN.pth --arch bsrgan --num-block 23 \
    --out BSRGAN.mlpackage --description "BSRGAN x4" \
    --attribution "Apache-2.0, github.com/cszn/BSRGAN"
```

BSRGAN.pth's checkpoint is the bare `state_dict` (no `"params"`/
`"params_ema"` wrapper key, unlike the xinntao checkpoints) — `convert.py`
detects `--arch bsrgan` and loads it directly, see that file.

**Produced as a `.mlmodel`, not `.mlpackage`, in this repo's actual commit**
— pass `--backend neuralnetwork --out BSRGAN.mlmodel` instead of the
command above if reproducing in an environment with the same
`libmilstoragepython`-missing limitation described in the OIDN section
below (this was, in fact, the case here); omit `--backend` entirely (the
`mlprogram` default, shown above) on a machine with a complete coremltools
install for a `.mlpackage` with FP16 weights instead — noticeably smaller
than this repo's current ~64MB FP32 `.mlmodel`.

## Converting Real-CUGAN (the "Toon / Cel-Shaded Render" upscale model)

Reproduces `../RealCUGAN.mlmodel` — also via `convert.py`, `--arch
realcugan`, but unlike BSRGAN this one is genuinely a different
architecture (a from-scratch U-Net, not RRDBNet — `realcugan_arch.py`),
not just a differently-named checkpoint of the same math:

```bash
mkdir -p realcugan_weights
curl -sL -o realcugan_weights/updated_weights.zip \
    "https://github.com/bilibili/ailab/releases/download/Real-CUGAN/updated_weights.zip"
unzip realcugan_weights/updated_weights.zip -d realcugan_weights

python3 convert.py --weights realcugan_weights/updated_weights/up4x-latest-no-denoise.pth \
    --arch realcugan --out RealCUGAN.mlpackage \
    --description "Real-CUGAN up4x (no-denoise)" --attribution "MIT, github.com/bilibili/ailab"
```

(`up4x-latest-no-denoise.pth` specifically, not `-conservative` or
`-denoise3x` — this app already has its own separate Denoise Before
Upscale toggle in Settings, so the base upscale model shouldn't also be
baking in its own fixed denoise strength on top of that.)

`realcugan_arch.py` is a from-scratch PyTorch reimplementation of
`upcunet_v3.py`'s `UpCunet4x` (`bilibili/ailab`, MIT) — `SEBlock`/
`UNetConv`/`UNet1`/`UNet2` copied over essentially verbatim (only the
training-only `kaiming_normal_` init loops stripped), but `UpCunet4x`
itself needed two real changes, not just a copy:

1. **Only the `tile_mode==0` forward path is ported.** The original
   `forward()` branches on a `tile_mode` argument — `tile_mode==0` is a
   single, straightforward pass over the whole input; `tile_mode>=1`
   implements the model's *own* internal chunking loop (crop into patches,
   run each, stitch back), meant for handling an arbitrarily large image
   in one Python call without exhausting GPU memory. That's irrelevant
   here — PixelBoost's `ImageTiler`/`CoreMLTileUpscaler` already do
   external fixed-128px-tile splitting — and the chunking branches'
   dynamic, data-dependent loop structure wouldn't trace/convert to Core
   ML cleanly anyway.
2. **Fixed-size input, and negative-padding calls rewritten as slicing.**
   The original computes its padding target (`ph`/`pw`) from the input
   tensor's own runtime shape — necessary for arbitrary image sizes, but
   coremltools' int-cast op can't handle that non-constant scalar
   arithmetic during tracing. Since PixelBoost only ever feeds this a
   fixed 128x128 tile (already even), `ph == h0` and `pw == w0` hold
   trivially, so the padding math was replaced with the constant it always
   evaluates to. Separately, several internal crop steps use PyTorch's
   `F.pad(x, (-n, -n, -n, -n))` idiom (negative padding = crop) — valid
   PyTorch, but coremltools' `pad` op raises outright on a negative value.
   Replaced with equivalent plain slicing (`x[:, :, n:-n, n:-n]`, see
   `_crop()`). Verified this rewrite changes nothing: ran the original
   negative-`F.pad` version and the sliced version on an identical test
   tile and confirmed bit-identical output before touching the conversion
   pipeline at all.

Same "no wrapper key" checkpoint format as BSRGAN (see above) — plain
`torch.load()` gives the state_dict directly — except Real-CUGAN's "pro"
variant checkpoints also carry an extra non-tensor `"pro"` marker key
alongside the real weights (see `bilibili/ailab`'s own
`RealWaifuUpScaler`); `convert.py` strips it if present, though the
`no-denoise` weights used here don't actually have it.

Same `.mlmodel`-not-`.mlpackage` caveat as BSRGAN and OIDN (below) applies
here too if reproducing in an environment with the same
`libmilstoragepython` limitation — pass `--backend neuralnetwork --out
RealCUGAN.mlmodel` in that case.

## Converting the Render Denoise model (OIDN)

Separate from the four Real-ESRGAN models above — reproduces
`../OIDNRenderDenoise.mlmodel`. Same Python/torch/coremltools setup as
above, plus `numpy` (already a torch dependency):

```bash
mkdir -p oidn_weights
curl -sL -o oidn_weights/rt_ldr_small.tza \
    "https://media.githubusercontent.com/media/RenderKit/oidn-weights/master/rt_ldr_small.tza"
# NOT https://raw.githubusercontent.com/... for this one — that repo stores
# .tza files via Git LFS, so the plain raw URL serves a small LFS pointer
# text file, not the actual ~620KB binary weights.

python3 convert_oidn.py --weights oidn_weights/rt_ldr_small.tza --out OIDNRenderDenoise.mlmodel
```

`tza.py` is Intel's own TZA (Tensor Archive) reader, vendored unmodified
from `oidn`'s `training/tza.py` (Apache-2.0) — the pretrained `.tza` weights
Intel ships are *not* a PyTorch/ONNX checkpoint, just this custom binary
tensor format, so this is a real dependency, not a convenience copy.
`oidn_unet.py` is a from-scratch PyTorch reimplementation of the "small" RT
U-Net architecture (`oidn`'s `training/model.py`, same license) — parameter
names match the original 1:1 (`enc_conv0`, `dec_conv1b`, ...) specifically
so `rt_ldr_small.tza`'s 32 tensors (all stored `oihw`, PyTorch `Conv2d`'s
own native weight layout) load directly via `load_state_dict`, no
renaming/transposition needed.

**Produces a `.mlmodel`, not a `.mlpackage`, unlike the other four models**
— `ct.convert(..., convert_to="neuralnetwork")` explicitly, not the default
`mlprogram` backend `convert.py` uses. This was a practical workaround, not
a deliberate choice: the machine this was converted on (Linux, Python 3.14)
had no working `coremltools.libmilstoragepython` — a compiled native
extension the `mlprogram`/`.mlpackage` backend needs to externalize weights
into a separate blob file, and PyPI has never published a Linux wheel for
any coremltools version that includes it (only an ancient `0.8`/py3.6
build). The legacy `neuralnetwork` backend embeds weights directly in the
protobuf spec instead, sidestepping that dependency entirely, and produces
a fully equivalent model — Xcode compiles either format into the same
`.mlmodelc` at build time, and nothing on the Swift side (`project.yml`'s
`sources:`, `CoreMLTileUpscaler`) cares which one a given model started as.
If converting on a machine with a real `coremltools[libmilstoragepython]`
install (e.g. actual macOS, or a from-source Linux build), passing
`convert_to="mlprogram"` — `convert.py`'s default, just omit the argument
entirely — would produce a `.mlpackage` instead, for consistency with the
other four; nothing else about `convert_oidn.py` would need to change.

Same `Wrapped` 0-255-in/0-255-out convention as `convert.py`'s Real-ESRGAN
wrapper (see above) — OIDN's LDR filter already expects plain
display-referred `[0,1]` color (a rendered PNG/JPEG straight off a render
engine, no linear/EXR tonemapping step needed), which lines up with what
`ImageType(scale=1/255)` produces from a 0-255 image.

`Config(tileSize: 128, scaleFactor: 1, overlap: 8)` on the Swift side (see
`RenderDenoiseService`) — `scaleFactor: 1` because this model denoises in
place, it doesn't upscale, unlike every other bundled model. 128 already
satisfies the model's own 16px alignment requirement (4 pooling stages,
each halving), so no extra input padding was needed in the wrapper.
