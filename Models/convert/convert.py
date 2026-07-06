import argparse

import coremltools as ct
import torch
import torch.nn as nn

from rrdbnet import RRDBNet

TILE_SIZE = 128  # must match PixelBoost's CoreMLTileUpscaler.Config.tileSize


class Wrapped(nn.Module):
    """Bakes Real-ESRGAN's pixel-range convention into the graph so the
    compiled model can take/return plain 0-255 images directly, with no
    manual normalization needed on the Swift side:
    - Input: coremltools' ImageType(scale=1/255) preprocessing divides the
      incoming 0-255 image down to the [0,1] float range the base model
      expects, before this wrapper even runs.
    - Output: the base model's raw output isn't guaranteed to land exactly
      in [0,1] (some pixels can overshoot), so clamp then scale back up to
      0-255 here, in-graph, before it's declared as an output ImageType.
    """

    def __init__(self, base: nn.Module):
        super().__init__()
        self.base = base

    def forward(self, x):
        out = self.base(x)
        out = torch.clamp(out, 0.0, 1.0) * 255.0
        return out


def main():
    parser = argparse.ArgumentParser(description="Convert a Real-ESRGAN RRDBNet checkpoint to Core ML.")
    parser.add_argument("--weights", default="RealESRGAN_x4plus.pth", help="Path to the .pth checkpoint")
    parser.add_argument("--num-block", type=int, default=23, help="RRDBNet num_block (23 for x4plus, 6 for anime_6B)")
    parser.add_argument("--out", default="RealESRGAN.mlpackage", help="Output .mlpackage path")
    parser.add_argument("--description", default="Real-ESRGAN x4plus", help="Short description baked into the model")
    args = parser.parse_args()

    base = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=args.num_block, num_grow_ch=32)
    state = torch.load(args.weights, map_location="cpu", weights_only=True)
    base.load_state_dict(state["params_ema"])
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
        f"{args.description} (BSD-3-Clause, github.com/xinntao/Real-ESRGAN) — "
        f"fixed {TILE_SIZE}x{TILE_SIZE} input, 4x output, for tiled use via ImageTiler."
    )
    mlmodel.save(args.out)
    print(f"Saved {args.out}")


if __name__ == "__main__":
    main()
