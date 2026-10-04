import UIKit

/// A single strategy for turning a smaller image into a larger, sharper one.
/// `CoreMLTileUpscaler` (a real super-resolution model) and `LanczosUpscaler`
/// (a plain resampling fallback) both conform to this so `UpscalerViewModel`
/// doesn't need to know which one it's driving.
protocol ImageUpscaling {
    /// Static description of this strategy's configuration — doesn't depend
    /// on any particular run, so it's available even to log a *failed*
    /// upscale (which technique/model/tile-config was attempted).
    var techniqueInfo: UpscaleTechniqueInfo { get }

    /// Returns an upscaled copy of `image`. `progress` is called from an
    /// arbitrary background context with a value in 0...1 and may be called
    /// zero or more times before completion.
    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult

    /// Same, under a run session (pause/resume, power mode, live preview
    /// frames). Strategies with nothing to pause or preview — a single
    /// Lanczos pass — just ignore the session.
    func upscale(_ image: UIImage, session: UpscaleSession?, progress: @escaping (Double) -> Void) async throws -> UpscaleResult
}

extension ImageUpscaling {
    func upscale(_ image: UIImage, session: UpscaleSession?, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        try await upscale(image, progress: progress)
    }
}

/// Fixed per-strategy configuration, independent of any particular run —
/// used both to drive the upscale and to describe what was attempted for
/// logging (see `UpscaleLogEntry`).
struct UpscaleTechniqueInfo {
    /// "coreml_tile" or "lanczos_fallback" — matches the server's
    /// `upscale_history.technique` column.
    let technique: String
    let modelName: String?
    let tileSize: Int?
    let overlap: Int?
    let scaleFactor: Int
}

/// What one particular upscale run actually produced — as opposed to
/// `UpscaleTechniqueInfo`, which describes the strategy regardless of
/// whether a given run succeeds.
struct UpscaleResult {
    let image: UIImage
    /// Number of tiles the image was split into — nil for strategies that
    /// don't tile (e.g. `LanczosUpscaler`).
    let tileCount: Int?
    /// The size the model was actually fed. Since every upscale now runs
    /// the full-resolution source through the model this equals the source
    /// size; still logged to `upscale_history.model_input_width/height` so
    /// old and new rows stay comparable. nil for `LanczosUpscaler`.
    var modelInputSize: CGSize? = nil
    /// True when the requested output would not fit in memory and the
    /// final canvas was made smaller than asked. The model still processed
    /// every source pixel either way.
    var outputWasCapped: Bool = false
    /// PSNR (dB) between the source and the result shrunk back to source
    /// size — how faithfully the upscale reproduces the original. Only
    /// measured when a fidelity pass ran.
    var fidelityPSNR: Double? = nil
    /// Tiles served from the duplicate-tile cache instead of the model.
    var tilesReused: Int = 0
    /// Highest resident footprint actually observed *during* the run, in MB.
    ///
    /// The log used to fill its `peak_memory_mb` column with a single
    /// `TelemetryService.usedMemoryMB` sample taken at log time — i.e. after
    /// the run had finished and every tile buffer had been released. On real
    /// telemetry that read 76-198MB for 4x upscales whose own memory
    /// warnings had recorded 2,160MB, which is to say it was measuring the
    /// idle footprint and calling it a peak. nil for strategies that don't
    /// sample (the caller falls back to the old after-the-fact reading).
    var peakMemoryMB: Int? = nil

    /// Same run metadata, new pixels (for post-passes like blend/sharpen).
    func replacingImage(_ image: UIImage) -> UpscaleResult {
        UpscaleResult(
            image: image, tileCount: tileCount, modelInputSize: modelInputSize,
            outputWasCapped: outputWasCapped, fidelityPSNR: fidelityPSNR,
            tilesReused: tilesReused, peakMemoryMB: peakMemoryMB
        )
    }
}

enum UpscaleError: LocalizedError {
    case modelNotBundled(String)
    case noModelOutput
    case renderFailed
    case invalidImage
    case photoLibraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .modelNotBundled(let name):
            return "No compiled Core ML model named \"\(name)\" is bundled with the app. "
                + "Drop a converted model into the Models/ folder — see Models/README.md."
        case .noModelOutput:
            return "The model ran but produced no image output."
        case .renderFailed:
            return "Failed to render the upscaled image."
        case .invalidImage:
            return "The selected image couldn't be read."
        case .photoLibraryAccessDenied:
            return "Photo library access was denied — enable it in Settings to save the upscaled image."
        }
    }
}
