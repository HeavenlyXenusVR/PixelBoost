import torch
from torch import nn as nn
from torch.nn import functional as F

# Real-CUGAN's UpCunet4x architecture, copied from bilibili/ailab's
# Real-CUGAN/upcunet_v3.py (MIT license) — SEBlock/UNetConv/UNet1/UNet2
# copied verbatim (only the training-only kaiming_normal_ init loops
# stripped, dead code at inference time), UpCunet4x reduced to ONLY its
# `tile_mode==0` forward path (upcunet_v3.py's other tile_mode branches
# implement the model's OWN internal chunking loop for handling a whole
# image in one call — irrelevant here since PixelBoost's ImageTiler already
# does external fixed-size tiling+overlap; tile_mode==0's single-pass path
# is the one that actually applies to a fixed 128x128 tile). Also drops the
# original forward()'s trailing `(x * 255).round().clamp_(0, 255).byte()` —
# kept as a raw float here so convert.py's shared `Wrapped` class can do
# that exact 0-255 conversion the same way for every model, rather than
# this one model quantizing twice.


def _crop(x, n):
    """Equivalent to the original's `F.pad(x, (-n, -n, -n, -n))` — negative
    padding as a crop, a valid PyTorch idiom coremltools' `pad` op rejects
    outright ("pad must be non-negative integer"). Plain slicing converts
    cleanly and is exactly the same operation."""
    return x[:, :, n:-n, n:-n]


class SEBlock(nn.Module):
    def __init__(self, in_channels, reduction=8, bias=False):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, in_channels // reduction, 1, 1, 0, bias=bias)
        self.conv2 = nn.Conv2d(in_channels // reduction, in_channels, 1, 1, 0, bias=bias)

    def forward(self, x):
        x0 = torch.mean(x, dim=(2, 3), keepdim=True)
        x0 = self.conv1(x0)
        x0 = F.relu(x0, inplace=True)
        x0 = self.conv2(x0)
        x0 = torch.sigmoid(x0)
        return torch.mul(x, x0)


class UNetConv(nn.Module):
    def __init__(self, in_channels, mid_channels, out_channels, se):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_channels, mid_channels, 3, 1, 0),
            nn.LeakyReLU(0.1, inplace=True),
            nn.Conv2d(mid_channels, out_channels, 3, 1, 0),
            nn.LeakyReLU(0.1, inplace=True),
        )
        self.seblock = SEBlock(out_channels, reduction=8, bias=True) if se else None

    def forward(self, x):
        z = self.conv(x)
        if self.seblock is not None:
            z = self.seblock(z)
        return z


class UNet1(nn.Module):
    def __init__(self, in_channels, out_channels, deconv):
        super().__init__()
        self.conv1 = UNetConv(in_channels, 32, 64, se=False)
        self.conv1_down = nn.Conv2d(64, 64, 2, 2, 0)
        self.conv2 = UNetConv(64, 128, 64, se=True)
        self.conv2_up = nn.ConvTranspose2d(64, 64, 2, 2, 0)
        self.conv3 = nn.Conv2d(64, 64, 3, 1, 0)
        self.conv_bottom = (
            nn.ConvTranspose2d(64, out_channels, 4, 2, 3) if deconv else nn.Conv2d(64, out_channels, 3, 1, 0)
        )

    def forward(self, x):
        x1 = self.conv1(x)
        x2 = self.conv1_down(x1)
        x1 = _crop(x1, 4)
        x2 = F.leaky_relu(x2, 0.1, inplace=True)
        x2 = self.conv2(x2)
        x2 = self.conv2_up(x2)
        x2 = F.leaky_relu(x2, 0.1, inplace=True)
        x3 = self.conv3(x1 + x2)
        x3 = F.leaky_relu(x3, 0.1, inplace=True)
        return self.conv_bottom(x3)


class UNet2(nn.Module):
    def __init__(self, in_channels, out_channels, deconv):
        super().__init__()
        self.conv1 = UNetConv(in_channels, 32, 64, se=False)
        self.conv1_down = nn.Conv2d(64, 64, 2, 2, 0)
        self.conv2 = UNetConv(64, 64, 128, se=True)
        self.conv2_down = nn.Conv2d(128, 128, 2, 2, 0)
        self.conv3 = UNetConv(128, 256, 128, se=True)
        self.conv3_up = nn.ConvTranspose2d(128, 128, 2, 2, 0)
        self.conv4 = UNetConv(128, 64, 64, se=True)
        self.conv4_up = nn.ConvTranspose2d(64, 64, 2, 2, 0)
        self.conv5 = nn.Conv2d(64, 64, 3, 1, 0)
        self.conv_bottom = (
            nn.ConvTranspose2d(64, out_channels, 4, 2, 3) if deconv else nn.Conv2d(64, out_channels, 3, 1, 0)
        )

    def forward(self, x, alpha=1.0):
        x1 = self.conv1(x)
        x2 = self.conv1_down(x1)
        x1 = _crop(x1, 16)
        x2 = F.leaky_relu(x2, 0.1, inplace=True)
        x2 = self.conv2(x2)
        x3 = self.conv2_down(x2)
        x2 = _crop(x2, 4)
        x3 = F.leaky_relu(x3, 0.1, inplace=True)
        x3 = self.conv3(x3)
        x3 = self.conv3_up(x3)
        x3 = F.leaky_relu(x3, 0.1, inplace=True)
        x4 = self.conv4(x2 + x3)
        x4 = x4 * alpha
        x4 = self.conv4_up(x4)
        x4 = F.leaky_relu(x4, 0.1, inplace=True)
        x5 = self.conv5(x1 + x4)
        x5 = F.leaky_relu(x5, 0.1, inplace=True)
        return self.conv_bottom(x5)


class UpCunet4x(nn.Module):
    """`tile_mode==0` only — see module docstring. `alpha`/`pro` (the
    original's enhancement-strength and output-curve knobs) are fixed at
    their defaults (1.0 / False), same "no adjustable parameter" convention
    as every other bundled upscale model.

    Also hardcoded to a fixed, even (H, W) input — the original computes
    `ph`/`pw` (padding targets) from the input's own runtime shape to
    support arbitrary-sized images in one call, but that dynamic
    shape-dependent arithmetic doesn't trace/convert to Core ML cleanly
    (coremltools' int-cast op chokes on a non-constant scalar). PixelBoost
    only ever feeds this a fixed `TILE_SIZE`x`TILE_SIZE` tile (128, already
    even) via `ImageTiler`, so `ph == h0` and `pw == w0` always hold in
    practice anyway — the original's `if w0 != pw or h0 != ph` crop-back
    branch this drops was already always a no-op for that input size.
    """

    def __init__(self, in_channels=3, out_channels=3):
        super().__init__()
        self.unet1 = UNet1(in_channels, 64, deconv=True)
        self.unet2 = UNet2(64, 64, deconv=False)
        self.ps = nn.PixelShuffle(2)
        self.conv_final = nn.Conv2d(64, 12, 3, 1, padding=0, bias=True)

    def forward(self, x):
        x00 = x
        x = F.pad(x, (19, 19, 19, 19), "reflect")
        x = self.unet1.forward(x)
        x0 = self.unet2.forward(x, 1.0)
        x1 = _crop(x, 20)
        x = torch.add(x0, x1)
        x = self.conv_final(x)
        x = _crop(x, 1)
        x = self.ps(x)
        x = x + F.interpolate(x00, scale_factor=4, mode="nearest")
        return x
