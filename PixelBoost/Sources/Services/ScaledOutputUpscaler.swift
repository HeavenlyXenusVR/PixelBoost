import CoreGraphics
import UIKit

/// Wraps any `ImageUpscaling` and resizes its output to a different final
/// scale than the base strategy's native one — e.g. a Core ML model that's
/// architecturally fixed at 4x can still deliver a 2x or 3x *final* image
/// this way. Downsampling a sharper 4x result is a better source of detail
/// for a smaller target than any model trained to output that ratio
/// directly would be for the tile sizes this app uses, so this is a
/// deliberate design choice, not a shortcut around real 2x/3x models.
///
/// `techniqueInfo`/logging still reports the *base* strategy's native scale
/// factor (e.g. 4), not the final requested one — it describes how the
/// model itself was invoked. The actual delivered size is always accurate
/// via the result image's own dimensions (`UpscaleRunner` logs
/// `output_width`/`output_height` straight from `result.image.size`), so
/// the two figures stay individually correct even though they can differ.
struct ScaledOutputUpscaler: ImageUpscaling {
    let base: ImageUpscaling
    let nativeScale: Int
    let targetScale: Int

    var techniqueInfo: UpscaleTechniqueInfo { base.techniqueInfo }

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        let result = try await base.upscale(image, progress: progress)
        guard targetScale != nativeScale else { return result }

        let targetSize = CGSize(
            width: (image.size.width * CGFloat(targetScale)).rounded(),
            height: (image.size.height * CGFloat(targetScale)).rounded()
        )
        let resized = Self.resize(result.image, to: targetSize)
        return UpscaleResult(image: resized, tileCount: result.tileCount)
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
