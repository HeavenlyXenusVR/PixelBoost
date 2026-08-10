# TinyEXR

Vendored from [syoyo/tinyexr](https://github.com/syoyo/tinyexr) (BSD-3-Clause,
includes portions of Industrial Light & Magic's OpenEXR reference code under
the same license family — see `LICENSE`). **Not actually single-header
despite the docs' framing**: `tinyexr.h` unconditionally `#include`s
`exr_reader.hh`, which in turn unconditionally includes `streamreader.hh` —
both vendored alongside it here (found the hard way: the CI archive step
failed with `'exr_reader.hh' file not found` on the first release build
after this was added, since only `tinyexr.h` had been copied over
initially). Chain terminates at `streamreader.hh` — no further local
`#include "..."`s. Two other conditional includes (`nanozlib.h`, `zfp.h`)
stay unvendored since they're gated behind `TINYEXR_USE_NANOZLIB`/
`TINYEXR_USE_ZFP`, both left at their default-off here.

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
