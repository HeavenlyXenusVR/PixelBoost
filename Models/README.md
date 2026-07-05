# Models

Drop a compiled Core ML super-resolution model here as `RealESRGAN.mlmodel`
(or change `modelName` in `CoreMLTileUpscaler.init` to match a different
filename) and rebuild — `CoreMLTileUpscaler` picks it up automatically and
the "no model bundled" banner in the app disappears. Nothing else in the
code needs to change as long as the model's input/output shape matches the
`Config` defaults below (or you update them to match).

This folder is empty by design (see `.gitignore`) — `.mlmodel`/`.mlpackage`
files are large binaries usually licensed separately from the app code, so
don't commit one here without checking its license permits redistribution.

## Getting a model

Real-ESRGAN (anime/general 4x models) is the most commonly converted
option, but any single-image super-resolution model that takes a
fixed-size image tile and outputs a `scaleFactor`x larger tile will work
the same way. Two practical paths:

1. **Find one already converted.** Search Hugging Face / GitHub for
   "Real-ESRGAN coreml" or "super resolution mlmodel" — several people have
   published pre-converted `.mlpackage`/`.mlmodel` files for exactly this
   use case. Check the license before shipping it.
2. **Convert one yourself** with [`coremltools`](https://coremltools.readme.io/):
   - Export the PyTorch/ONNX Real-ESRGAN model to a fixed input size (e.g.
     128x128) — Core ML strongly prefers static shapes for image models.
   - Use `coremltools.convert(...)` with
     `inputs=[ct.ImageType(...)]` and `outputs=[ct.ImageType(...)]` so the
     compiled model takes/returns `CVPixelBuffer`s directly — this is what
     lets `CoreMLTileUpscaler` use `VNCoreMLRequest` /
     `VNPixelBufferObservation` without any manual pixel-format handling.
   - Save as `.mlpackage`, then either drag it into this folder (Xcode
     compiles `.mlpackage` the same as `.mlmodel`) or run
     `xcrun coremlcompiler compile RealESRGAN.mlpackage .` to get an
     `.mlmodelc` directly.

## Matching `CoreMLTileUpscaler.Config`

| Config field | Must equal |
|---|---|
| `tileSize` | The model's fixed input width/height, in pixels |
| `scaleFactor` | The model's output size ÷ input size (4 for a typical 4x model) |
| `overlap` | Your choice — context pixels fed to the model beyond what's kept; 8-16 is reasonable for a 128px tile |

If the model expects something other than 128x128 input or isn't a 4x
model, update the `Config` defaults in `CoreMLTileUpscaler.swift` (or pass a
non-default `Config` when constructing it in `UpscalerViewModel`) to match.
