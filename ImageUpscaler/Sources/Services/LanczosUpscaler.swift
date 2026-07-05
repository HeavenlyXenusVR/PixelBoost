import CoreImage
import UIKit

/// Plain Lanczos resampling via Core Image — no ML model required, so the app
/// always has a working upscaler even before a Core ML model is bundled.
/// Sharper than the system's default bilinear resize, but it's still just
/// interpolation: it can't invent detail the way a trained super-resolution
/// model can. Swap in `CoreMLTileUpscaler` for real quality once a model is
/// bundled (see Models/README.md).
struct LanczosUpscaler: ImageUpscaling {
    var scaleFactor: Double = 4

    private static let context = CIContext()

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UIImage {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }
        let ciImage = CIImage(cgImage: cgImage)

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            throw UpscaleError.renderFailed
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scaleFactor, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let output = filter.outputImage,
              let rendered = Self.context.createCGImage(output, from: output.extent) else {
            throw UpscaleError.renderFailed
        }
        progress(1.0)
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
