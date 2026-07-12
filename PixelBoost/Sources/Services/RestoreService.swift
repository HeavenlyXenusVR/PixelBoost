import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// Two "old/rough photo" fixes, both built from stock frameworks rather
/// than a trained restoration model — a real GFPGAN/CodeFormer-class
/// generative face-restoration model has the same blind-conversion problem
/// as the rest of this app's Core ML pipeline, but with far less certain
/// payoff with no device here to check its actual output on.
enum RestoreService {
    private static let context = CIContext()

    /// `amount` 0...1 — scales both the noise-reduction strength and how
    /// much fine detail (`sharpness`) is preserved alongside it, per
    /// `CINoiseReduction`'s own two parameters.
    static func denoise(_ image: UIImage, amount: Double) -> UIImage {
        guard amount > 0, let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)

        let filter = CIFilter.noiseReduction()
        filter.inputImage = ciImage
        filter.noiseLevel = Float(0.02 + amount * 0.08)
        filter.sharpness = Float(0.4 + amount * 0.2)

        guard let output = filter.outputImage,
              let rendered = context.createCGImage(output, from: ciImage.extent) else {
            return image
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    /// Locates faces with Vision, then blends a sharpened/detail-boosted
    /// version of the photo back in just over those regions (feathered
    /// ellipses around each detected face, same `CIBlendWithMask`
    /// compositing `SelectiveAdjustmentService` uses — just with a
    /// face-geometry mask instead of a user brush stroke). Returns `nil`
    /// if no faces are found, so the caller can tell the user there was
    /// nothing to restore rather than silently handing back the original.
    static func restoreFaces(_ image: UIImage) async -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let faces = request.results, !faces.isEmpty else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let maskImage = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { rendererContext in
            UIColor.black.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            for face in faces {
                // Vision's boundingBox is normalized with a bottom-left
                // origin; UIKit drawing is top-left, so the Y needs
                // flipping. Expanded by 25% so the feathered mask covers
                // a little beyond the jawline/hairline, not just the
                // tight face box.
                let box = face.boundingBox
                let rect = CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                ).insetBy(dx: -box.width * width * 0.25, dy: -box.height * height * 0.25)
                rendererContext.cgContext.fillEllipse(in: rect)
            }
        }
        guard let maskCG = maskImage.cgImage else { return nil }

        // Feather the hard ellipse edge so the sharpened region blends
        // smoothly instead of showing a visible boundary. Clamp before
        // blurring so the blur doesn't pull in transparent/black pixels
        // from beyond the image edge.
        let maskCI = CIImage(cgImage: maskCG)
        let blurredMask = maskCI
            .clampedToExtent()
            .applyingGaussianBlur(radius: Double(min(width, height)) * 0.02)
            .cropped(to: maskCI.extent)

        let ciImage = CIImage(cgImage: cgImage)
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = ciImage
        sharpen.sharpness = 0.8
        guard let sharpened = sharpen.outputImage else { return nil }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = sharpened
        blend.backgroundImage = ciImage
        blend.maskImage = blurredMask

        guard let output = blend.outputImage,
              let rendered = context.createCGImage(output, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
