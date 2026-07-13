import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum CloneStampError: LocalizedError {
    case invalidImage
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Couldn't read the photo or the marked area to clone."
        case .processingFailed: return "Couldn't process the clone stamp."
        }
    }
}

/// Classic clone-stamp: pick a source point, then paint elsewhere to copy
/// pixels from a fixed offset relative to that source point — the offset
/// stays constant as the brush moves, so painting a stroke copies a swept
/// region from the source area, not just a single point.
///
/// Implemented as one full-image translation (`CIAffineTransform`, shifting
/// the whole photo by the offset) blended back over the original only
/// within the painted mask (`CIBlendWithMask`, the same compositing pattern
/// `InpaintingService`/`SelectiveAdjustmentService`/`RestoreService` all
/// use) — this composites the entire stroke at once rather than sampling
/// per-pixel along the drag, which is simpler and behaves identically since
/// the offset never changes mid-stroke anyway.
enum CloneStampService {
    private static let context = CIContext()

    /// `maskImage` must be the same pixel size as `image` — white marks the
    /// painted (destination) area, black leaves the photo untouched.
    /// `offset` is in the same top-left/y-down pixel space as the mask
    /// (`BrushMask`'s rasterization space): `sourcePixel = paintedPixel +
    /// offset`.
    static func apply(_ image: UIImage, maskImage: UIImage, offset: CGPoint) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try render(image, maskImage: maskImage, offset: offset)
        }.value
    }

    private static func render(_ image: UIImage, maskImage: UIImage, offset: CGPoint) throws -> UIImage {
        guard let cgImage = image.cgImage, let maskCGImage = maskImage.cgImage else {
            throw CloneStampError.invalidImage
        }
        let original = CIImage(cgImage: cgImage)
        let mask = CIImage(cgImage: maskCGImage)

        // `offset` arrives in top-left/y-down pixel space, but CIImage's
        // coordinate space is bottom-left/y-up — the x component carries
        // over as-is, but the y component's sign has to flip (the same
        // kind of flip RestoreService needs for Vision's boundingBox).
        // Uses CIImage's own `transformed(by:)` rather than the
        // `CIFilter.affineTransform()` builtin — the CI runner's SDK
        // doesn't expose that builtin (mirrors the `applyingGaussianBlur`
        // vs. `CIFilter.gaussianBlur()` surface mismatch found earlier;
        // this time the safer, more stable API is the plain CIImage method
        // rather than a CIFilterBuiltins wrapper).
        let transform = CGAffineTransform(translationX: -offset.x, y: offset.y)
        let shifted = original.clampedToExtent().transformed(by: transform).cropped(to: original.extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = shifted
        blend.backgroundImage = original
        blend.maskImage = mask
        guard let blended = blend.outputImage else {
            throw CloneStampError.processingFailed
        }

        guard let rendered = context.createCGImage(blended, from: original.extent) else {
            throw CloneStampError.processingFailed
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
