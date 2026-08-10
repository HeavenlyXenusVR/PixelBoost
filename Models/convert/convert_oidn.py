import argparse

import coremltools as ct
import torch
import torch.nn as nn

from oidn_unet import OIDNUNetSmall
from tza import Reader

TILE_SIZE = 128  # must match PixelBoost's CoreMLTileUpscaler.Config.tileSize;
# also must be a multiple of the model's own 16px alignment (4 pooling
# stages), which 128 already satisfies.


def load_tza_state_dict(path: str) -> dict:
    """rt_ldr_small.tza's 32 tensors are already named identically to
    OIDNUNetSmall's parameters (enc_conv0.weight, dec_conv1b.bias, ...) and
    stored 'oihw' — PyTorch Conv2d's own native weight layout — so this is a
    direct load, no transposition or renaming needed. See training/tza.py
    (github.com/RenderKit/oidn, Apache-2.0, vendored here) for the reader."""
    reader = Reader(path)
    state_dict = {}
    for name in reader._table:  # noqa: SLF001 — tza.Reader exposes no public iterator
        array, _layout = reader[name]
        state_dict[name] = torch.from_numpy(array.copy()).float()
    return state_dict


class Wrapped(nn.Module):
    """Same 0-255-in/0-255-out convention as convert.py's Real-ESRGAN
    wrapper, so CoreMLTileUpscaler's existing ImageType-based pipeline works
    unchanged for this model too — OIDN's LDR filter already expects plain
    display-referred [0,1] color (a rendered PNG/JPEG straight off a render
    engine, no linear/EXR tonemapping step needed), matching what
    coremltools' scale=1/255 preprocessing produces from a 0-255 image."""

    def __init__(self, base: nn.Module):
        super().__init__()
        self.base = base

    def forward(self, x):
        out = self.base(x)
        out = torch.clamp(out, 0.0, 1.0) * 255.0
        return out


def main():
    parser = argparse.ArgumentParser(
        description="Convert Intel Open Image Denoise's rt_ldr_small.tza (Apache-2.0) to Core ML."
    )
    parser.add_argument("--weights", default="oidn_weights/rt_ldr_small.tza", help="Path to the .tza weights file")
    parser.add_argument("--out", default="OIDNRenderDenoise.mlpackage", help="Output .mlpackage path")
    args = parser.parse_args()

    base = OIDNUNetSmall()
    base.load_state_dict(load_tza_state_dict(args.weights))
    base.eval()

    wrapped = Wrapped(base)
    wrapped.eval()

    example = torch.rand(1, 3, TILE_SIZE, TILE_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=(1, 3, TILE_SIZE, TILE_SIZE), scale=1.0 / 255.0, bias=[0, 0, 0])],
        outputs=[ct.ImageType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )
    mlmodel.short_description = (
        "Intel Open Image Denoise 'rt_ldr_small' (Apache-2.0, github.com/RenderKit/oidn) — "
        f"fixed {TILE_SIZE}x{TILE_SIZE} input, same-resolution output (denoise, no upscale), "
        "for tiled use via ImageTiler with scaleFactor=1."
    )
    mlmodel.save(args.out)
    print(f"Saved {args.out}")


if __name__ == "__main__":
    main()
