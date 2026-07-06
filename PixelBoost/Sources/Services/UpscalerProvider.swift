import Foundation

/// Which bundled Core ML model to use. Each case's `modelName` must match a
/// compiled model in Models/ (see Models/README.md) — resolving a choice
/// whose model isn't actually bundled falls back to `LanczosUpscaler`
/// rather than throwing, same as the original single-model behavior.
enum UpscaleModelChoice: String, CaseIterable, Identifiable {
    case generalPhoto
    case anime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generalPhoto: return "General Photo"
        case .anime: return "Anime / Illustration"
        }
    }

    var modelName: String {
        switch self {
        case .generalPhoto: return "RealESRGAN"
        case .anime: return "RealESRGANAnime"
        }
    }

    /// Cheap synchronous existence check (no MLModel load) — lets the UI
    /// show a "not bundled" state without needing a full async resolve.
    var isBundled: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
    }
}

/// How much time to trade for quality. Tile size (128) is baked into the
/// bundled models' fixed compiled input shape and can't vary per preset —
/// the only safely-adjustable axis is context overlap, plus the choice of
/// whether to use a model at all.
enum UpscaleQuality: String, CaseIterable, Identifiable {
    case fast
    case standard
    case best

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .standard: return "Standard"
        case .best: return "Best"
        }
    }

    /// nil means "skip the model entirely" — `.fast` uses `LanczosUpscaler`.
    var overlap: Int? {
        switch self {
        case .fast: return nil
        case .standard: return 8
        case .best: return 16
        }
    }
}

/// Resolves the `ImageUpscaling` strategy to use for a run, based on the
/// user's model/quality selection, and caches loaded Core ML models by name
/// so switching quality presets back and forth doesn't reload the
/// (expensive) MLModel — only `CoreMLTileUpscaler.updateOverlap(_:)` needs
/// to run for that. Shared by `UpscalerViewModel` and
/// `BatchUpscaleViewModel` via one instance injected at the app level, so a
/// model switch in Settings is visible to whichever screen runs next.
@MainActor
final class UpscalerProvider: ObservableObject {
    private static let modelChoiceDefaultsKey = "com.pixelboost.modelChoice"
    private static let qualityDefaultsKey = "com.pixelboost.quality"

    @Published var modelChoice: UpscaleModelChoice {
        didSet { UserDefaults.standard.set(modelChoice.rawValue, forKey: Self.modelChoiceDefaultsKey) }
    }
    @Published var quality: UpscaleQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityDefaultsKey) }
    }
    /// True while a not-yet-cached model is being loaded — lets the UI show
    /// a spinner instead of silently hitching on the first use of a given
    /// model.
    @Published private(set) var isLoadingModel = false

    private var cache: [String: CoreMLTileUpscaler] = [:]

    init() {
        modelChoice = UserDefaults.standard.string(forKey: Self.modelChoiceDefaultsKey)
            .flatMap(UpscaleModelChoice.init(rawValue:)) ?? .generalPhoto
        quality = UserDefaults.standard.string(forKey: Self.qualityDefaultsKey)
            .flatMap(UpscaleQuality.init(rawValue:)) ?? .standard
    }

    /// Resolves the upscaler for the *current* model/quality selection.
    /// Call again after either changes.
    func resolveCurrent() async -> ImageUpscaling {
        guard let overlap = quality.overlap else {
            return LanczosUpscaler()
        }

        let choice = modelChoice
        if let cached = cache[choice.modelName] {
            cached.updateOverlap(overlap)
            return cached
        }

        isLoadingModel = true
        defer { isLoadingModel = false }

        let modelName = choice.modelName
        let config = CoreMLTileUpscaler.Config(tileSize: 128, scaleFactor: 4, overlap: overlap)
        let loaded = await Task.detached(priority: .userInitiated) {
            try? CoreMLTileUpscaler(modelName: modelName, config: config)
        }.value

        guard let loaded else {
            // Model failed to load (not bundled, corrupt, etc.) — don't
            // cache the failure under this key, so a later retry (e.g.
            // after an app update that adds the model) can succeed.
            return LanczosUpscaler()
        }
        cache[choice.modelName] = loaded
        return loaded
    }
}
