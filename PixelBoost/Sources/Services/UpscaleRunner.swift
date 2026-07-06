import UIKit

/// Runs one upscale via `upscaler`, builds the matching `UpscaleLogEntry`,
/// and posts it — shared by `UpscalerViewModel` (single image) and
/// `BatchUpscaleViewModel` (queue) so this construction isn't duplicated
/// between them.
enum UpscaleRunner {
    struct Outcome {
        let result: UpscaleResult?
        let error: Error?
    }

    /// - Parameter sourceFileSizeBytes: from the original encoded photo
    ///   data, if available — see `UpscalerViewModel.load(from:)` for why
    ///   this is the only point it's ever known.
    static func run(
        _ sourceImage: UIImage,
        using upscaler: ImageUpscaling,
        sourceFileSizeBytes: Int?,
        progress: @escaping (Double) -> Void
    ) async -> Outcome {
        let startedAt = Date()
        do {
            let result = try await upscaler.upscale(sourceImage, progress: progress)
            log(
                upscaler: upscaler, sourceImage: sourceImage, sourceFileSizeBytes: sourceFileSizeBytes,
                outputImage: result.image, tileCount: result.tileCount, startedAt: startedAt, error: nil
            )
            return Outcome(result: result, error: nil)
        } catch {
            log(
                upscaler: upscaler, sourceImage: sourceImage, sourceFileSizeBytes: sourceFileSizeBytes,
                outputImage: nil, tileCount: nil, startedAt: startedAt, error: error
            )
            return Outcome(result: nil, error: error)
        }
    }

    private static func log(
        upscaler: ImageUpscaling, sourceImage: UIImage, sourceFileSizeBytes: Int?,
        outputImage: UIImage?, tileCount: Int?, startedAt: Date, error: Error?
    ) {
        let info = upscaler.techniqueInfo
        let entry = UpscaleLogEntry(
            device_id: DeviceIdentity.current,
            source_width: Int(sourceImage.size.width),
            source_height: Int(sourceImage.size.height),
            source_file_size_bytes: sourceFileSizeBytes,
            technique: info.technique,
            model_name: info.modelName,
            tile_size: info.tileSize,
            overlap: info.overlap,
            scale_factor: info.scaleFactor,
            tile_count: tileCount,
            output_width: outputImage.map { Int($0.size.width) },
            output_height: outputImage.map { Int($0.size.height) },
            processing_ms: Int(Date().timeIntervalSince(startedAt) * 1000),
            success: error == nil,
            error_message: error?.localizedDescription,
            app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            os_version: UIDevice.current.systemVersion,
            device_model: UIDevice.current.model
        )
        UpscaleLoggingService.log(entry)
    }
}
