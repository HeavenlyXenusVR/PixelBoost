import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Wraps `CoreMLTileUpscaler` around the converted Intel Open Image Denoise
/// 'rt_ldr_small' model (Apache-2.0, github.com/RenderKit/oidn — see
/// Models/README.md and Models/convert/convert_oidn.py for how it was
/// converted) — the same beauty-only filter Blender's Cycles Denoise node
/// uses, aimed at the fireflies/blotchy noise a low-sample-count render
/// leaves behind, as opposed to Restore's generic `CINoiseReduction` pass
/// (tuned for sensor/ISO noise on real photos, a different noise
/// character). `scaleFactor: 1` — this model denoises in place, it doesn't
/// upscale, unlike every other bundled Core ML model.
///
/// The model itself has no strength parameter — it denoises at one fixed
/// intensity. `strength` below is applied *after* inference by
/// cross-dissolving the denoised result back over the original, which is
/// the only knob available short of retraining: at 1.0 you get the model's
/// raw output (the previous, only behavior), and below that a proportional
/// mix, so an over-aggressive pass on a lightly-noisy render can be dialed
/// back instead of being all-or-nothing. The model always runs at full
/// strength regardless, so timing is unaffected by this setting.
enum RenderDenoiseService {
    /// Cached the same "load once, reuse" way `UpscalerProvider` caches its
    /// own `CoreMLTileUpscaler` instances — model load is real I/O, running
    /// it isn't.
    private static var cached: CoreMLTileUpscaler?

    /// - Parameter strength: 0...1, defaults to 1.0 (the model's raw
    ///   output — the behavior before this parameter existed). A strength
    ///   of 0 short-circuits and returns `image` untouched rather than
    ///   running the model for a result that would be entirely discarded.
    static func denoise(
        _ image: UIImage,
        strength: Double = 1.0,
        progress: @escaping (Double) -> Void
    ) async throws -> UIImage {
        let clamped = min(1, max(0, strength))
        guard clamped > 0 else { return image }
        let upscaler = try cachedUpscaler()
        let result = try await upscaler.upscale(image, progress: progress)
        guard clamped < 1 else { return result.image }
        return mixed(result.image, over: image, amount: clamped) ?? result.image
    }

    private static let blendContext = CIContext()

    /// `amount` 1 is entirely `denoised`, 0 entirely `original`. Returns
    /// `nil` on any failure so the caller can fall back to the full-strength
    /// result — a blend that didn't work out is not worth failing the whole
    /// denoise over.
    private static func mixed(_ denoised: UIImage, over original: UIImage, amount: Double) -> UIImage? {
        guard let denoisedCG = denoised.cgImage, let originalCG = original.cgImage else { return nil }
        let denoisedCI = CIImage(cgImage: denoisedCG)
        var originalCI = CIImage(cgImage: originalCG)
        // This model is scaleFactor 1, so both should already match
        // exactly; resize defensively anyway, since
        // `CIDissolveTransition` otherwise clips to the intersection of
        // its two inputs and would silently crop an edge on an
        // off-by-a-pixel mismatch (same guard `UpscaleRunner.crossDissolve`
        // keeps for its own blend).
        if originalCI.extent.size != denoisedCI.extent.size,
           originalCI.extent.width > 0, originalCI.extent.height > 0 {
            originalCI = originalCI.transformed(by: CGAffineTransform(
                scaleX: denoisedCI.extent.width / originalCI.extent.width,
                y: denoisedCI.extent.height / originalCI.extent.height
            ))
        }

        let filter = CIFilter.dissolveTransition()
        filter.inputImage = originalCI
        filter.targetImage = denoisedCI
        filter.time = Float(amount)
        guard let output = filter.outputImage,
              let rendered = blendContext.createCGImage(output, from: denoisedCI.extent)
        else { return nil }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    private static func cachedUpscaler() throws -> CoreMLTileUpscaler {
        if let cached { return cached }
        let upscaler = try CoreMLTileUpscaler(
            modelName: "OIDNRenderDenoise",
            config: CoreMLTileUpscaler.Config(tileSize: 128, scaleFactor: 1, overlap: 8)
        )
        cached = upscaler
        return upscaler
    }
}
