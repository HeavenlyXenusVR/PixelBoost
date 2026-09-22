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
        antiAliasingAmount: Double = 0,
        sharpenAmount: Double = 0,
        autoRenderDenoise: Bool = false,
        blendAmount: Double = 1.0,
        detailLevel: String? = nil,
        requestedScale: Int? = nil,
        isBatch: Bool = false,
        progress: @escaping (Double) -> Void
    ) async -> Outcome {
        let startedAt = Date()
        // Captured before the run so the log can show whether the phone was
        // *already* hot going in, as opposed to having been heated by this
        // run — the distinction the v3.26.17 thermal change was made
        // without any data on.
        let thermalStateStart = TelemetryService.thermalStateName
        let context = TelemetryService.context
        let settings = RunSettings(
            detailLevel: detailLevel, requestedScale: requestedScale,
            strength: blendAmount, antiAliasing: antiAliasingAmount,
            sharpen: sharpenAmount, denoiseBefore: denoiseAmount > 0 || autoRenderDenoise,
            isBatch: isBatch, thermalStateStart: thermalStateStart, context: context
        )
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
                result = UpscaleResult(
                    image: ImageTransform.antiAliased(result.image, amount: antiAliasingAmount),
                    tileCount: result.tileCount, modelInputSize: result.modelInputSize
                )
            }
            if sharpenAmount > 0 {
                result = UpscaleResult(
                    image: PostSharpen.apply(result.image, amount: sharpenAmount),
                    tileCount: result.tileCount, modelInputSize: result.modelInputSize
                )
            }
            log(
                upscaler: upscaler, sourceImage: sourceImage, sourceFileSizeBytes: sourceFileSizeBytes,
                outputImage: result.image, tileCount: result.tileCount, startedAt: startedAt, error: nil,
                modelInputSize: result.modelInputSize, settings: settings
            )
            // Feeds the Home Screen widget (see UpscaleSnapshot) — every
            // successful run through this shared function, single-image or
            // batch alike, since both funnel through here.
            UpscaleSnapshot.record(resultThumbnail: result.image)
            return Outcome(result: result, error: nil)
        } catch {
            log(
                upscaler: upscaler, sourceImage: sourceImage, sourceFileSizeBytes: sourceFileSizeBytes,
                outputImage: nil, tileCount: nil, startedAt: startedAt, error: error,
                modelInputSize: nil, settings: settings
            )
            return Outcome(result: nil, error: error)
        }
    }

    /// Cross-dissolves `result.image` with a plain Lanczos resize of
    /// `sourceImage` at the result's own final size — `amount` 0 is
    /// entirely the plain resize, 1 entirely the model result. The scale is
    /// read off the actual result, not `techniqueInfo.scaleFactor`: that's
    /// the model's native 4x, which for a 2x target meant building a 4x
    /// Lanczos copy (16x the source's pixels) just to shrink it again.
    /// `nil` on any failure (falls back to the unblended model result, same
    /// "best-effort enhancement pass" reasoning as `autoRenderDenoise`
    /// above).
    private static func blended(_ result: UpscaleResult, sourceImage: UIImage, upscaler: ImageUpscaling, amount: Double) async -> UpscaleResult? {
        guard let sourceWidth = sourceImage.cgImage?.width, sourceWidth > 0,
              let resultWidth = result.image.cgImage?.width else { return nil }
        let scale = Double(resultWidth) / Double(sourceWidth)
        guard scale > 0,
              let fallback = try? await LanczosUpscaler(scaleFactor: scale).upscale(sourceImage, progress: { _ in }),
              let blendedImage = crossDissolve(result.image, fallback.image, amount: amount)
        else { return nil }
        return UpscaleResult(image: blendedImage, tileCount: result.tileCount, modelInputSize: result.modelInputSize)
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

    /// The run's own configuration plus the device context it started in —
    /// bundled rather than threaded through `log` as a dozen loose
    /// parameters.
    private struct RunSettings {
        let detailLevel: String?
        let requestedScale: Int?
        let strength: Double
        let antiAliasing: Double
        let sharpen: Double
        let denoiseBefore: Bool
        let isBatch: Bool
        let thermalStateStart: String
        let context: TelemetryService.Context
    }

    private static func log(
        upscaler: ImageUpscaling, sourceImage: UIImage, sourceFileSizeBytes: Int?,
        outputImage: UIImage?, tileCount: Int?, startedAt: Date, error: Error?,
        modelInputSize: CGSize?, settings: RunSettings
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
            device_model: UIDevice.current.model,
            detail_level: settings.detailLevel,
            model_input_width: modelInputSize.map { Int($0.width) },
            model_input_height: modelInputSize.map { Int($0.height) },
            requested_scale: settings.requestedScale,
            upscale_strength: settings.strength,
            anti_aliasing: settings.antiAliasing,
            sharpen: settings.sharpen,
            denoise_before: settings.denoiseBefore,
            was_batch: settings.isBatch,
            cancelled: error is CancellationError,
            thermal_state_start: settings.thermalStateStart,
            thermal_state_end: TelemetryService.thermalStateName,
            low_power_mode: settings.context.lowPowerMode,
            battery_level: settings.context.batteryLevel,
            physical_memory_mb: settings.context.physicalMemoryMB,
            peak_memory_mb: TelemetryService.usedMemoryMB
        )
        // Metadata (timing/dimensions/success) is the always-on debug
        // telemetry described in the README — off only if the user turns
        // Diagnostics off in Settings (see TelemetryService.isEnabled).
        //
        // The image bytes themselves are two separate, independently
        // switchable concerns, both read here from UserDefaults rather than
        // an UpscalerProvider instance (UpscaleRunner has none to read the
        // published properties from):
        //
        // 1. Temporary Cloud Save — keeps a copy of the *result* on the
        //    server for a day (the TTL is a setting) so it can be re-fetched
        //    from the Cloud tab or another device without re-running the
        //    model. Uploaded with is_auto so an automatic copy can be told
        //    apart from a deliberate one-off.
        // 2. Auto Cloud Backup — the older, broader opt-in: uploads the
        //    *source* photo as well.
        //
        // Neither is permanent: every row carries expires_at and the server
        // deletes it on expiry (see server/README.md's Expiry section).
        let temporarySaveEnabled = UpscalerProvider.storedTemporaryCloudSaveEnabled
        let temporaryTTLHours = UpscalerProvider.storedTemporaryCloudTTLHours
        let autoCloudBackupEnabled = UserDefaults.standard.bool(forKey: UpscalerProvider.autoCloudBackupEnabledDefaultsKey)
        let uploadLabel = [info.modelName, settings.requestedScale.map { "\($0)x" }, settings.detailLevel]
            .compactMap { $0 }
            .joined(separator: " · ")
        guard TelemetryService.isEnabled || temporarySaveEnabled || autoCloudBackupEnabled else { return }
        Task.detached(priority: .background) {
            let historyID = TelemetryService.isEnabled ? await UpscaleLoggingService.log(entry) : nil
            guard let outputImage, temporarySaveEnabled || autoCloudBackupEnabled else { return }
            // Independent, best-effort attempts (a failed source upload
            // shouldn't skip the arguably-more-important result upload) —
            // whichever fails last just wins the status banner, which is
            // fine for a lightweight "something's not getting backed up"
            // signal rather than a precise per-upload report.
            var lastError: Error?
            if autoCloudBackupEnabled {
                do { try await ImportExportService.upload(sourceImage, kind: .imports, isAuto: true) } catch { lastError = error }
            }
            if temporarySaveEnabled || autoCloudBackupEnabled {
                do {
                    try await ImportExportService.upload(
                        outputImage, kind: .exports, historyID: historyID,
                        ttlHours: temporaryTTLHours, isAuto: true, label: uploadLabel
                    )
                } catch { lastError = error }
            }
            if let lastError {
                await CloudBackupStatus.shared.reportFailure(lastError)
            } else {
                await CloudBackupStatus.shared.reportSuccess()
            }
        }
    }
}
