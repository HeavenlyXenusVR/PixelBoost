import UIKit

/// Wraps a `CoreMLTileUpscaler` so it delivers a different final scale than
/// the model's native one — e.g. a Core ML model that's architecturally
/// fixed at 4x can still deliver a 2x or 3x *final* image. The resize
/// happens per tile inside `CoreMLTileUpscaler.upscale(_:outputScale:...)`:
/// each tile's sharper 4x output is downsampled straight into a target-size
/// canvas, which is a better source of detail for a smaller target than any
/// model trained to output that ratio directly would be for the tile sizes
/// this app uses, and never allocates a 4x-sized intermediate.
///
/// `techniqueInfo`/logging still reports the *base* model's native scale
/// factor (e.g. 4), not the final requested one — it describes how the
/// model itself was invoked. The actual delivered size is always accurate
/// via the result image's own dimensions (`UpscaleRunner` logs
/// `output_width`/`output_height` straight from `result.image.size`), so
/// the two figures stay individually correct even though they can differ.
struct ScaledOutputUpscaler: ImageUpscaling {
    let base: CoreMLTileUpscaler
    let targetScale: Int
    /// See `UpscaleDetail.maxModelInputPixels`.
    let maxModelInputPixels: Double

    var techniqueInfo: UpscaleTechniqueInfo { base.techniqueInfo }

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        try await base.upscale(
            image, outputScale: Double(targetScale),
            maxModelInputPixels: maxModelInputPixels, progress: progress
        )
    }
}
