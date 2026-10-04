import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Manual touch-up for a Cutout result. `BackgroundRemovalService` relies
/// entirely on Vision's own segmentation quality, and until this existed a
/// miss had no recourse at all: if it clipped an arm off the subject or
/// kept a wedge of background, the only options were to re-run the same
/// request and get the same answer, or give up on the cutout.
///
/// Two brush polarities, both driven by the same painted `BrushStroke`
/// mask every other brush tool in this app produces (see `BrushMask`):
///
/// - `.restore` paints the *original* photo's pixels back in, for a part of
///   the subject the mask wrongly cut away. Needs the pre-cutout original,
///   which is why `refine` takes it separately — the cutout itself has
///   nothing but transparency where those pixels used to be, so there is
///   no way to recover them from it alone.
/// - `.erase` clears to transparent, for background the mask wrongly kept.
///
/// Compositing is `CIBlendWithMask` with a slightly blurred mask, the same
/// pattern `RestoreService`/`SelectiveAdjustmentService` use — a hard
/// stroke edge against a feathered Vision matte reads as an obvious
/// paint-over, and a couple of pixels of feather is enough to hide the
/// difference.
enum CutoutRefineService {
    enum Brush {
        /// Bring the original photo's pixels back within the stroke.
        case restore
        /// Clear to transparent within the stroke.
        case erase
    }

    private static let context = CIContext()

    /// - Parameter cutout: the current (already background-removed) image.
    /// - Parameter original: the pre-cutout photo. Required for `.restore`;
    ///   ignored for `.erase`.
    /// - Parameter mask: black/white, white where the brush painted, at
    ///   `cutout`'s pixel size (see `BrushMask.rasterize`).
    /// - Returns: `nil` if the inputs can't be read, or if `.restore` was
    ///   asked for with no original to restore from — the caller surfaces
    ///   that rather than handing back an unchanged image that looks like
    ///   the brush silently did nothing.
    static func refine(
        _ cutout: UIImage,
        original: UIImage?,
        mask: UIImage,
        brush: Brush
    ) -> UIImage? {
        guard let cutoutCG = cutout.cgImage, let maskCG = mask.cgImage else { return nil }
        let cutoutCI = CIImage(cgImage: cutoutCG)
        let extent = cutoutCI.extent

        let foreground: CIImage
        switch brush {
        case .restore:
            guard let originalCG = original?.cgImage else { return nil }
            var originalCI = CIImage(cgImage: originalCG)
            // The original is normally the same pixel size as the cutout
            // (background removal doesn't resample), but a cutout that has
            // since been through another tool — Crop, or an upscale —
            // won't match. Scale to the cutout's extent so the restored
            // pixels land where the brush actually painted instead of
            // offset by the size difference.
            if originalCI.extent.size != extent.size,
               originalCI.extent.width > 0, originalCI.extent.height > 0 {
                originalCI = originalCI.transformed(by: CGAffineTransform(
                    scaleX: extent.width / originalCI.extent.width,
                    y: extent.height / originalCI.extent.height
                ))
            }
            foreground = originalCI
        case .erase:
            foreground = CIImage(color: .clear).cropped(to: extent)
        }

        var maskCI = CIImage(cgImage: maskCG)
        if maskCI.extent.size != extent.size, maskCI.extent.width > 0, maskCI.extent.height > 0 {
            maskCI = maskCI.transformed(by: CGAffineTransform(
                scaleX: extent.width / maskCI.extent.width,
                y: extent.height / maskCI.extent.height
            ))
        }
        // Clamp before blurring so the blur doesn't pull transparent pixels
        // in from beyond the mask's edge and soften a stroke that runs right
        // up to the border, then crop back (same clamp/crop pairing
        // `RestoreService.restoreFaces` uses for its own feathered mask).
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = maskCI.clampedToExtent()
        blur.radius = Float(max(1, min(extent.width, extent.height) * 0.002))
        let feathered = (blur.outputImage ?? maskCI).cropped(to: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = cutoutCI
        blend.maskImage = feathered

        guard let output = blend.outputImage,
              let rendered = context.createCGImage(output, from: extent)
        else { return nil }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
