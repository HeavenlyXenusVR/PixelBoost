import CoreImage
import CoreImage.CIFilterBuiltins
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
    /// - Parameter denoiseAmount: 0...1, run via `RestoreService.denoise`
    ///   on `sourceImage` *before* it's handed to `upscaler` — cheap
    ///   relative to the upscale itself, and only ever applied to the copy
    ///   fed to the model, never to what gets logged/returned as the
    ///   "source" for anything else.
    /// - Parameter antiAliasingAmount: 0...1, a gentle blur pass applied to
    ///   the final result to smooth jagged edges after the upscale itself.
    /// - Parameter sharpenAmount: 0...1, run via `PostSharpen` on the
    ///   result *after* upscaling succeeds — a no-op on failure, since
    ///   there's nothing to sharpen.
    /// - Parameter autoRenderDenoise: runs the same model `RenderDenoiseView`
    ///   uses (see `RenderDenoiseService`) on `sourceImage` *before*
    ///   `upscaler`, same "only the copy fed to the model" scoping as
    ///   `denoiseAmount` above — set when Auto mode picked a render-tuned
    ///   model (BSRGAN/Real-CUGAN) for this photo, since a render's own
    ///   noise character is exactly what that model expects to have
    ///   already been cleaned up before upscaling, not left for the SR
    ///   model to amplify. Best-effort: a failure here (e.g. the model
    ///   somehow isn't bundled) silently falls back to the undenoised
    ///   image rather than failing the whole upscale over an enhancement
    ///   step, same reasoning as `ActionLoggingService` never blocking the
    ///   action it's describing.
    /// - Parameter blendAmount: 0...1, 1.0 (default, unchanged) is the
    ///   model's raw output. Below that, the model still runs (so timing/
    ///   history still reflect the real model), but its result is
    ///   cross-dissolved with a plain Lanczos resize of `sourceImage` at
    ///   the same final size — a way to dial back an over-aggressive or
    ///   artifact-prone model's effect without switching models entirely.
    ///   Applied before `sharpenAmount` so a low blend still gets sharpened
    ///   if requested, rather than sharpen running on the pre-blend result.
    static func run(
        _ sourceImage: UIImage,
        using upscaler: ImageUpscaling,
        sourceFileSizeBytes: Int?,
        denoiseAmount: Double = 0,
        antiAliasingAmount: Double = 0.35,
        sharpenAmount: Double = 0,
        autoRenderDenoise: Bool = false,
        blendAmount: Double = 1.0,
        progress: @escaping (Double) -> Void
    ) async -> Outcome {
        let startedAt = Date()
        var upscalerInput = denoiseAmount > 0 ? RestoreService.denoise(sourceImage, amount: denoiseAmount) : sourceImage
        if autoRenderDenoise {
            upscalerInput = (try? await RenderDenoiseService.denoise(upscalerInput) { _ in }) ?? upscalerInput
        }
        do {
            var result = try await upscaler.upscale(upscalerInput, progress: progress)
            if blendAmount < 1.0 {
                result = await blended(result, sourceImage: sourceImage, upscaler: upscaler, amount: blendAmount) ?? result
            }
            if antiAliasingAmount > 0 {
                result = UpscaleResult(image: ImageTransform.antiAliased(result.image, amount: antiAliasingAmount), tileCount: result.tileCount)
            }
            if sharpenAmount > 0 {
                result = UpscaleResult(image: PostSharpen.apply(result.image, amount: sharpenAmount), tileCount: result.tileCount)
            }
            log(
                upscaler: upscaler, sourceImage: sourceImage, sourceFileSizeBytes: sourceFileSizeBytes,
                outputImage: result.image, tileCount: result.tileCount, startedAt: startedAt, error: nil
            )
            // Feeds the Home Screen widget (see UpscaleSnapshot) — every
            // successful run through this shared function, single-image or
            // batch alike, since both funnel through here.
            UpscaleSnapshot.record(resultThumbnail: result.image)
            return Outcome(result: result, error: nil)
        } catch {
            log(
                upscaler: upscaler, sourceImage: sourceImage, sourceFileSizeBytes: sourceFileSizeBytes,
                outputImage: nil, tileCount: nil, startedAt: startedAt, error: error
            )
            return Outcome(result: nil, error: error)
        }
    }

    /// Cross-dissolves `result.image` with a plain Lanczos resize of
    /// `sourceImage` at the same final scale (read off `upscaler`'s own
    /// `techniqueInfo`, so this matches whatever scale was actually
    /// requested) — `amount` 0 is entirely the plain resize, 1 entirely
    /// the model result. `nil` on any failure (falls back to the
    /// unblended model result, same "best-effort enhancement pass"
    /// reasoning as `autoRenderDenoise` above).
    private static func blended(_ result: UpscaleResult, sourceImage: UIImage, upscaler: ImageUpscaling, amount: Double) async -> UpscaleResult? {
        let scale = Double(upscaler.techniqueInfo.scaleFactor)
        guard scale > 0,
              let fallback = try? await LanczosUpscaler(scaleFactor: scale).upscale(sourceImage, progress: { _ in }),
              let blendedImage = crossDissolve(result.image, fallback.image, amount: amount)
        else { return nil }
        return UpscaleResult(image: blendedImage, tileCount: result.tileCount)
    }

    private static let blendContext = CIContext()

    private static func crossDissolve(_ modelOutput: UIImage, _ fallback: UIImage, amount: Double) -> UIImage? {
        guard let modelCGImage = modelOutput.cgImage, let fallbackCGImage = fallback.cgImage else { return nil }
        let modelImage = CIImage(cgImage: modelCGImage)
        var fallbackImage = CIImage(cgImage: fallbackCGImage)
        // Both should already be the same size (same source, same scale
        // factor), but the two upscalers round tile/tap boundaries
        // slightly differently — resize defensively so CIDissolveTransition
        // (which otherwise clips to the intersection of its two inputs)
        // never produces a visibly cropped edge on an off-by-a-few-pixels
        // mismatch.
        if fallbackImage.extent.size != modelImage.extent.size, fallbackImage.extent.width > 0, fallbackImage.extent.height > 0 {
            let scaleX = modelImage.extent.width / fallbackImage.extent.width
            let scaleY = modelImage.extent.height / fallbackImage.extent.height
            fallbackImage = fallbackImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        let filter = CIFilter.dissolveTransition()
        filter.inputImage = fallbackImage
        filter.targetImage = modelImage
        filter.time = Float(min(1, max(0, amount)))
        guard let output = filter.outputImage,
              let rendered = blendContext.createCGImage(output, from: modelImage.extent)
        else { return nil }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
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
        // Metadata (timing/dimensions/success) always gets logged — that's
        // the always-on debug telemetry described in the README. The image
        // bytes themselves are a separate, opt-in concern (Settings' "Auto
        // Cloud Backup") gated here on autoCloudBackupEnabledDefaultsKey:
        // UpscaleRunner has no UpscalerProvider instance to read the
        // published property from directly, so it reads the same
        // UserDefaults key the property mirrors. When on, this uploads the
        // source/result pair to the same expiring scratch storage the
        // manual "Cloud Backup" button uses (see ImportExportService) —
        // tied together via history_id so a model's actual input/output
        // can be inspected server-side, not just the dimensions/timing
        // metadata above. Every upload here is still TTL'd (default 24h,
        // see server/README.md), not permanent retention.
        let autoCloudBackupEnabled = UserDefaults.standard.bool(forKey: UpscalerProvider.autoCloudBackupEnabledDefaultsKey)
        Task.detached(priority: .background) {
            let historyID = await UpscaleLoggingService.log(entry)
            guard autoCloudBackupEnabled, let historyID else { return }
            // Independent, best-effort attempts (a failed source upload
            // shouldn't skip the arguably-more-important result upload) —
            // whichever fails last just wins the status banner, which is
            // fine for a lightweight "something's not getting backed up"
            // signal rather than a precise per-upload report.
            var lastError: Error?
            do { try await ImportExportService.upload(sourceImage, kind: .imports) } catch { lastError = error }
            if let outputImage {
                do { try await ImportExportService.upload(outputImage, kind: .exports, historyID: historyID) } catch { lastError = error }
            }
            if let lastError {
                await CloudBackupStatus.shared.reportFailure(lastError)
            } else {
                await CloudBackupStatus.shared.reportSuccess()
            }
        }
    }
}
