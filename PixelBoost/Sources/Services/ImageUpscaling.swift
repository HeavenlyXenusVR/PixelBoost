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
