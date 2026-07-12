import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum InpaintingError: LocalizedError {
    case invalidImage
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Couldn't read the photo or the marked area to erase."
        case .processingFailed: return "Couldn't process the object removal."
        }
    }
}

/// Fills a masked region of a photo by diffusing color inward from its
/// unmasked surroundings — repeated, growing-radius Gaussian blurs with the
/// original (unmasked) pixels re-imposed after every pass. This is a
/// classical PDE-style "heat diffusion" fill (the masked region relaxes
/// toward a smooth solution with the surrounding pixels held fixed as
/// boundary values), not a generative model: unlike Cutout, there's no
/// on-device Vision-framework shortcut for object removal, and training or
/// blind-converting a generative inpainting model — no GPU here, no
/// simulator/device to look at its output before it ships — was judged too
/// large a risk to bet this feature on. Works well for small objects or
/// blemishes over fairly uniform backgrounds; large or heavily textured
/// regions will come out smeared rather than reconstructed, since nothing
/// here invents texture, it only smooths color inward. See
/// `Views/InpaintView.swift` for the mask-painting UI this feeds.
enum InpaintingService {
    private static let context = CIContext()

    /// `maskImage` must be the same pixel size as `image` — white marks
    /// the area to erase, black leaves the photo untouched.
    static func fill(_ image: UIImage, maskImage: UIImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try render(image, maskImage: maskImage)
        }.value
    }

    private static func render(_ image: UIImage, maskImage: UIImage) throws -> UIImage {
        guard let cgImage = image.cgImage, let maskCGImage = maskImage.cgImage else {
            throw InpaintingError.invalidImage
        }
        let original = CIImage(cgImage: cgImage)
        let mask = CIImage(cgImage: maskCGImage)

        // Iteration count and radius growth are a hand-picked heuristic,
        // not tuned against real output (no way to look at one here) —
        // growing the radius each pass lets information reach further into
        // the masked region without needing many more iterations.
        let iterations = 8
        let baseRadius = max(original.extent.width, original.extent.height) * 0.012

        var current = original
        for pass in 1...iterations {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = current.clampedToExtent()
            blur.radius = Float(baseRadius * Double(pass))
            guard let blurred = blur.outputImage?.cropped(to: original.extent) else { continue }

            let blend = CIFilter.blendWithMask()
            blend.inputImage = blurred
            blend.backgroundImage = original
            blend.maskImage = mask
            guard let blended = blend.outputImage else { continue }
            current = blended
        }

        guard let rendered = context.createCGImage(current, from: original.extent) else {
            throw InpaintingError.processingFailed
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
