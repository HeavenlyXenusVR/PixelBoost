import torch
import torch.nn as nn
import torch.nn.functional as F

# Reimplementation of Intel Open Image Denoise's "small" RT U-Net
# (github.com/RenderKit/oidn training/model.py, Apache-2.0) — reproduced here
# rather than vendored wholesale since only this one architecture (in=3,
# out=3, small=True — the beauty-only LDR "rt_ldr_small" filter) is needed.
# Layer names match the original exactly so `load_tza_state_dict` in
# convert_oidn.py can map tensors 1:1 with no renaming.


def _conv(in_channels, out_channels):
    return nn.Conv2d(in_channels, out_channels, 3, padding=1)


class OIDNUNetSmall(nn.Module):
    """The 'small' RT filter variant: beauty-only (3ch in, 3ch out), no
    albedo/normal auxiliary buffers — matches rt_ldr_small.tza exactly.
    Requires H/W to be multiples of `alignment` (4 pooling stages, each
    halving), which PixelBoost's 128px tiles already satisfy."""

    def __init__(self):
        super().__init__()
        ec = 32  # every encoder stage is 32 channels in the small variant
        self.enc_conv0 = _conv(3, ec)
        self.enc_conv1 = _conv(ec, ec)
        self.enc_conv2 = _conv(ec, ec)
        self.enc_conv3 = _conv(ec, ec)
        self.enc_conv4 = _conv(ec, ec)
        self.enc_conv5a = _conv(ec, ec)
        self.enc_conv5b = _conv(ec, ec)
        self.dec_conv4a = _conv(ec + ec, 64)
        self.dec_conv4b = _conv(64, 64)
        self.dec_conv3a = _conv(64 + ec, 64)
        self.dec_conv3b = _conv(64, 64)
        self.dec_conv2a = _conv(64 + ec, 64)
        self.dec_conv2b = _conv(64, 32)
        self.dec_conv1a = _conv(32 + 3, 32)
        self.dec_conv1b = _conv(32, 32)
        self.dec_conv0 = _conv(32, 3)
        self.alignment = 16

    def forward(self, x):
        def relu(t):
            return F.relu(t, inplace=True)

        def pool(t):
            return F.max_pool2d(t, 2, 2)

        def upsample(t):
            return F.interpolate(t, scale_factor=2, mode="nearest")

        t = relu(self.enc_conv0(x))
        t = relu(self.enc_conv1(t))
        pool1 = t = pool(t)
        t = relu(self.enc_conv2(t))
        pool2 = t = pool(t)
        t = relu(self.enc_conv3(t))
        pool3 = t = pool(t)
        t = relu(self.enc_conv4(t))
        t = pool(t)
        t = relu(self.enc_conv5a(t))
        t = relu(self.enc_conv5b(t))

        t = upsample(t)
        t = torch.cat((t, pool3), 1)
        t = relu(self.dec_conv4a(t))
        t = relu(self.dec_conv4b(t))

        t = upsample(t)
        t = torch.cat((t, pool2), 1)
        t = relu(self.dec_conv3a(t))
        t = relu(self.dec_conv3b(t))

        t = upsample(t)
        t = torch.cat((t, pool1), 1)
        t = relu(self.dec_conv2a(t))
        t = relu(self.dec_conv2b(t))

        t = upsample(t)
        t = torch.cat((t, x), 1)
        t = relu(self.dec_conv1a(t))
        t = relu(self.dec_conv1b(t))

        return self.dec_conv0(t)
