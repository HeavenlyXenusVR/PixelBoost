import CoreImage
import UIKit
import Vision

enum BackgroundRemovalError: LocalizedError {
    case noSubjectDetected
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .noSubjectDetected:
            return "No distinct subject was found in this photo to cut out."
        case .processingFailed:
            return "Couldn't process this photo's background."
        }
    }
}

/// Cuts the main subject(s) out of a photo using Vision's on-device subject
/// segmentation (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+) — the
/// same technology behind Photos' own "Lift Subject" long-press. There's no
/// custom model to source, convert, or bundle here, unlike the upscaling
/// models in `Models/` — Vision ships this on every iOS 17 device.
enum BackgroundRemovalService {
    /// Returns a new image, the same pixel dimensions as `image`, with
    /// everything Vision didn't consider part of the main subject(s) made
    /// transparent. Throws `BackgroundRemovalError.noSubjectDetected` if
    /// Vision doesn't find anything to lift out (e.g. a flat texture or
    /// sky with no distinct foreground object).
    static func removeBackground(from image: UIImage) async throws -> UIImage {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }
        // VNImageRequestHandler.perform runs synchronously and can take
        // real time — same reasoning as CoreMLTileUpscaler's model calls,
        // dispatch off whatever cooperative-pool thread is awaiting this.
        return try await Task.detached(priority: .userInitiated) {
            try cutoutSubject(from: cgImage)
        }.value
    }

    private static func cutoutSubject(from cgImage: CGImage) throws -> UIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw BackgroundRemovalError.noSubjectDetected
        }

        // A single-channel mask (white over every detected subject
        // instance, black elsewhere), already resolved back to the
        // original image's own dimensions regardless of whatever internal
        // resolution Vision actually ran the segmentation network at.
        let maskBuffer = try result.generateMaskedImage(
            ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false
        )
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let subjectImage = CIImage(cgImage: cgImage)

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw BackgroundRemovalError.processingFailed
        }
        // CIBlendWithMask: input shows through where the mask is white,
        // background shows through where the mask is black — a fully
        // transparent CIImage as the background is what turns the masked-
        // out area into real alpha rather than a solid fill color.
        blend.setValue(subjectImage, forKey: kCIInputImageKey)
        blend.setValue(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: subjectImage.extent),
            forKey: kCIInputBackgroundImageKey
        )
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)

        guard let output = blend.outputImage else { throw BackgroundRemovalError.processingFailed }

        let context = CIContext()
        guard let rendered = context.createCGImage(
            output, from: subjectImage.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw BackgroundRemovalError.processingFailed
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
