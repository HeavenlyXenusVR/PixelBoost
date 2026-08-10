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
enum RenderDenoiseService {
    /// Cached the same "load once, reuse" way `UpscalerProvider` caches its
    /// own `CoreMLTileUpscaler` instances — model load is real I/O, running
    /// it isn't.
    private static var cached: CoreMLTileUpscaler?

    static func denoise(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UIImage {
        let upscaler = try cachedUpscaler()
        let result = try await upscaler.upscale(image, progress: progress)
        return result.image
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
