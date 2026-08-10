# TinyEXR

Vendored from [syoyo/tinyexr](https://github.com/syoyo/tinyexr) (BSD-3-Clause,
includes portions of Industrial Light & Magic's OpenEXR reference code under
the same license family — see `LICENSE`), `include/tinyexr.h` only — a
single-header C++ library, no other files needed.

Backs EXR import (`PixelBoost/Sources/Services/EXRDecoder.mm` — Objective-C++,
since tinyexr is C++ and Swift can only bridge to C/Objective-C directly) for
bringing a 3D-render beauty pass straight into PixelBoost without a manual
"flatten to PNG first" step. Configured with `TINYEXR_USE_MINIZ 0` — rather
than also vendoring miniz (tinyexr's bundled default zlib implementation),
`EXRDecoder.mm` includes the system `<zlib.h>` before `tinyexr.h`, and
`project.yml` links `libz.tbd` — iOS already ships zlib as a system library,
so there's no reason to duplicate it just to decompress ZIP-compressed EXR
channels (Blender's default EXR compression).

See `EXRDecoder.mm`'s doc comment for the tonemap (EXR is scene-linear HDR;
the rest of PixelBoost's pipeline assumes display-referred 0-255 like every
other image source) and `Models/README.md`-style "not run on-device yet"
caveat that applies here too.
