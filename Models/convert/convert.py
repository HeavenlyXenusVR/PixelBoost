import argparse

import coremltools as ct
import torch
import torch.nn as nn

from bsrgan_arch import RRDBNet as BSRGANRRDBNet
from realcugan_arch import UpCunet4x
from rrdbnet import RRDBNet
from srvgg_arch import SRVGGNetCompact

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
    parser = argparse.ArgumentParser(description="Convert a Real-ESRGAN checkpoint (RRDBNet or SRVGGNetCompact) to Core ML.")
    parser.add_argument("--weights", default="RealESRGAN_x4plus.pth", help="Path to the .pth checkpoint")
    parser.add_argument(
        "--arch", default="rrdbnet", choices=["rrdbnet", "srvgg", "bsrgan", "realcugan"],
        help="rrdbnet (x4plus/anime_6B/RealESRNet_x4plus), srvgg (realesr-general-x4v3 and friends), "
             "bsrgan (BSRGAN.pth — same RRDBNet math, older layer-naming convention, see bsrgan_arch.py), "
             "or realcugan (up4x-latest-*.pth — a different U-Net architecture entirely, see realcugan_arch.py)"
    )
    parser.add_argument("--num-block", type=int, default=23, help="RRDBNet num_block (23 for x4plus/RealESRNet, 6 for anime_6B)")
    parser.add_argument("--num-conv", type=int, default=32, help="SRVGGNetCompact num_conv (32 for general-x4v3, 16 for animevideov3)")
    parser.add_argument("--out", default="RealESRGAN.mlpackage", help="Output .mlpackage/.mlmodel path")
    parser.add_argument("--description", default="Real-ESRGAN x4plus", help="Short description baked into the model")
    parser.add_argument(
        "--attribution", default="BSD-3-Clause, github.com/xinntao/Real-ESRGAN",
        help="License/source line appended to the model's description"
    )
    parser.add_argument(
        "--backend", default="mlprogram", choices=["mlprogram", "neuralnetwork"],
        help="mlprogram produces a .mlpackage (needs a working coremltools.libmilstoragepython — "
             "not available in every environment, see Models/convert/README.md); neuralnetwork "
             "produces a flat .mlmodel with weights embedded directly, no native extension needed, "
             "functionally equivalent once Xcode compiles either into .mlmodelc"
    )
    args = parser.parse_args()

    if args.arch == "rrdbnet":
        base = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=args.num_block, num_grow_ch=32)
    elif args.arch == "bsrgan":
        base = BSRGANRRDBNet(in_nc=3, out_nc=3, nf=64, nb=args.num_block, gc=32, sf=4)
    elif args.arch == "realcugan":
        base = UpCunet4x(in_channels=3, out_channels=3)
    else:
        base = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=args.num_conv, upscale=4, act_type="prelu")

    state = torch.load(args.weights, map_location="cpu", weights_only=True)
    if args.arch in ("bsrgan", "realcugan"):
        # Both BSRGAN.pth and up4x-latest-*.pth are the bare state_dict, not
        # wrapped under a "params"/"params_ema" key the way xinntao's
        # checkpoints are. Real-CUGAN's "pro" variant checkpoints also carry
        # an extra non-tensor "pro" marker key alongside the real weights
        # (see bilibili/ailab's RealWaifuUpScaler) — the up4x-latest-*.pth
        # release weights used here don't have it, but strip it if present
        # so load_state_dict(strict=True) doesn't choke on an unexpected key.
        state.pop("pro", None)
        base.load_state_dict(state)
    else:
        # RRDBNet checkpoints store the EMA'd weights under "params_ema";
        # SRVGGNetCompact checkpoints (no EMA) store them under "params".
        key = "params_ema" if "params_ema" in state else "params"
        base.load_state_dict(state[key])
    base.eval()

    wrapped = Wrapped(base)
    wrapped.eval()

    example = torch.rand(1, 3, TILE_SIZE, TILE_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    convert_kwargs = dict(
        inputs=[ct.ImageType(name="input", shape=(1, 3, TILE_SIZE, TILE_SIZE), scale=1.0 / 255.0, bias=[0, 0, 0])],
        outputs=[ct.ImageType(name="output")],
        convert_to=args.backend,
    )
    if args.backend == "mlprogram":
        # compute_precision only applies to mlprogram — neuralnetwork has no
        # equivalent option (coremltools raises if passed one). iOS16+ is
        # required for mlprogram; PixelBoost's own deployment target (iOS
        # 17, project.yml) already exceeds this regardless.
        convert_kwargs["compute_precision"] = ct.precision.FLOAT16
        convert_kwargs["minimum_deployment_target"] = ct.target.iOS16
    else:
        # neuralnetwork predates the iOS15+ mlprogram requirement — passing
        # iOS16 here raises ("cannot be neuralnetwork"). Omitting it lets
        # coremltools pick a compatible minimum for this spec format; the
        # app's own IPHONEOS_DEPLOYMENT_TARGET (iOS 17) is what actually
        # gates real device compatibility, not this convert-time metadata.
        pass

    mlmodel = ct.convert(traced, **convert_kwargs)
    mlmodel.short_description = (
        f"{args.description} ({args.attribution}) — "
        f"fixed {TILE_SIZE}x{TILE_SIZE} input, 4x output, for tiled use via ImageTiler."
    )
    mlmodel.save(args.out)
    print(f"Saved {args.out}")


if __name__ == "__main__":
    main()
