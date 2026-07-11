import CoreImage
import Foundation
import UIKit

/// Which bundled Core ML model to use. Each case's `modelName` must match a
/// compiled model in Models/ (see Models/README.md) — resolving a choice
/// whose model isn't actually bundled falls back to `LanczosUpscaler`
/// rather than throwing, same as the original single-model behavior. Cases
/// beyond `generalPhoto`/`anime` aren't bundled yet (no matching
/// `.mlmodelc`) — they exist so the picker honestly shows where the model
/// lineup is headed, degrading the same "not bundled" way any missing model
/// already does rather than hiding the option entirely.
enum UpscaleModelChoice: String, CaseIterable, Identifiable {
    case auto
    case generalPhoto
    case anime
    case portrait
    case lowLight
    case textDocument

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .generalPhoto: return "General Photo"
        case .anime: return "Anime / Illustration"
        case .portrait: return "Portrait"
        case .lowLight: return "Low-Light"
        case .textDocument: return "Text & Documents"
        }
    }

    var modelName: String {
        switch self {
        case .auto: return ""
        case .generalPhoto: return "RealESRGAN"
        case .anime: return "RealESRGANAnime"
        case .portrait: return "RealESRGANPortrait"
        case .lowLight: return "RealESRGANLowLight"
        case .textDocument: return "RealESRGANText"
        }
    }

    /// Cheap synchronous existence check (no MLModel load) — lets the UI
    /// show a "not bundled" state without needing a full async resolve.
    /// `.auto` reports bundled as long as at least one real candidate is,
    /// since it never resolves to a model of its own.
    var isBundled: Bool {
        if self == .auto {
            return UpscaleModelChoice.allCases.contains { $0 != .auto && $0.isBundled }
        }
        return Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
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

    /// Side of the test region (before the model's own scale factor) run
    /// through each candidate during auto-selection. Big enough to span a
    /// handful of `CoreMLTileUpscaler` tiles — one flat 128x128 crop
    /// wouldn't reliably tell two models apart — small enough that testing
    /// every bundled candidate still finishes in a fraction of the real
    /// upscale's time.
    private static let autoTestRegionSize = 256

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
    /// True while `.auto` is running its candidate models over the test
    /// region — a separate flag from `isLoadingModel` since it can span
    /// loading *multiple* models, not just one.
    @Published private(set) var isTestingModels = false
    /// Which model `.auto` picked the last time it ran, so the UI can show
    /// "Auto picked General Photo" instead of leaving the choice invisible.
    @Published private(set) var lastAutoSelectedModel: UpscaleModelChoice?

    private var cache: [String: CoreMLTileUpscaler] = [:]

    init() {
        // Auto is the default for new installs — it's the whole point of
        // having more than one bundled model, so new users shouldn't have
        // to know to go find it in Settings.
        modelChoice = UserDefaults.standard.string(forKey: Self.modelChoiceDefaultsKey)
            .flatMap(UpscaleModelChoice.init(rawValue:)) ?? .auto
        quality = UserDefaults.standard.string(forKey: Self.qualityDefaultsKey)
            .flatMap(UpscaleQuality.init(rawValue:)) ?? .standard
    }

    /// Resolves the upscaler for the *current* model/quality selection.
    /// Call again after either changes. `sourceImage`, when provided, is
    /// used only to run `.auto`'s candidate test — it's `nil`-safe (falls
    /// back to the first bundled candidate) since not every caller has an
    /// image ready up front.
    func resolveCurrent(for sourceImage: UIImage? = nil) async -> ImageUpscaling {
        guard let overlap = quality.overlap else {
            return LanczosUpscaler()
        }

        let choice: UpscaleModelChoice
        if modelChoice == .auto {
            choice = await autoSelectModel(for: sourceImage, overlap: overlap) ?? .generalPhoto
            lastAutoSelectedModel = choice
        } else {
            choice = modelChoice
        }

        if let cached = cache[choice.modelName] {
            cached.updateOverlap(overlap)
            return cached
        }

        guard let loaded = await loadUpscaler(named: choice.modelName, overlap: overlap) else {
            return LanczosUpscaler()
        }
        cache[choice.modelName] = loaded
        return loaded
    }

    private func loadUpscaler(named modelName: String, overlap: Int) async -> CoreMLTileUpscaler? {
        isLoadingModel = true
        defer { isLoadingModel = false }

        let config = CoreMLTileUpscaler.Config(tileSize: 128, scaleFactor: 4, overlap: overlap)
        // Model failed to load (not bundled, corrupt, etc.) — the caller
        // doesn't cache a nil under this key, so a later retry (e.g. after
        // an app update that adds the model) can succeed.
        return await Task.detached(priority: .userInitiated) {
            try? CoreMLTileUpscaler(modelName: modelName, config: config)
        }.value
    }

    /// Runs every bundled real model over one shared crop of `sourceImage`
    /// and keeps whichever produced the sharpest, most-detailed result — a
    /// handful of quick tile-level tests standing in for "which model would
    /// actually look best on *this* photo" instead of a fixed default.
    /// Returns `nil` (caller falls back to `.generalPhoto`) if there's no
    /// image to test against or fewer than two real candidates to choose
    /// between.
    private func autoSelectModel(for sourceImage: UIImage?, overlap: Int) async -> UpscaleModelChoice? {
        let candidates = UpscaleModelChoice.allCases.filter { $0 != .auto && $0.isBundled }
        guard candidates.count > 1,
              let sourceImage,
              let testRegion = Self.centerTestRegion(of: sourceImage, maxSize: Self.autoTestRegionSize) else {
            return candidates.first
        }

        isTestingModels = true
        defer { isTestingModels = false }

        var best: (choice: UpscaleModelChoice, score: Double)?
        for candidate in candidates {
            guard let upscaler = await loadUpscaler(named: candidate.modelName, overlap: overlap) else { continue }
            // Cache it now, win or lose — if it wins, resolveCurrent's own
            // cache lookup reuses it instead of loading a second time; if
            // it loses, it's still legitimately warm for next time this
            // model is picked directly.
            cache[candidate.modelName] = upscaler

            guard let result = try? await upscaler.upscale(testRegion, progress: { _ in }) else { continue }
            let score = Self.sharpnessScore(result.image)
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        return best?.choice
    }

    /// A center crop, not a resize — auto-selection needs to see the model
    /// operating at native tiling resolution on real detail, not a
    /// downsampled stand-in that would blur away the texture differences
    /// between candidates.
    private static func centerTestRegion(of image: UIImage, maxSize: Int) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 32, height >= 32 else { return nil }

        let size = min(maxSize, width, height)
        let normalized = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        let rect = CGRect(
            x: CGFloat((width - size) / 2), y: CGFloat((height - size) / 2),
            width: CGFloat(size), height: CGFloat(size)
        )
        return normalized.cropped(to: rect)
    }

    /// No-reference sharpness/detail proxy: desaturate, run a Laplacian
    /// (edge-detection) convolution, and average the response over the
    /// whole image — a crisper, more-detailed upscale has a stronger mean
    /// edge response than a smoother or blurrier one. The same family of
    /// metric autofocus systems use to score "is this in focus," repurposed
    /// here to compare candidate models instead of camera lens positions.
    private static func sharpnessScore(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let ciImage = CIImage(cgImage: cgImage)

        guard let grayscale = CIFilter(name: "CIColorControls") else { return 0 }
        grayscale.setValue(ciImage, forKey: kCIInputImageKey)
        grayscale.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let grayImage = grayscale.outputImage else { return 0 }

        guard let laplacian = CIFilter(name: "CIConvolution3X3") else { return 0 }
        laplacian.setValue(grayImage, forKey: kCIInputImageKey)
        laplacian.setValue(CIVector(values: [0, -1, 0, -1, 4, -1, 0, -1, 0], count: 9), forKey: "inputWeights")
        laplacian.setValue(0.0, forKey: "inputBias")
        guard let edges = laplacian.outputImage else { return 0 }

        guard let averageFilter = CIFilter(name: "CIAreaAverage") else { return 0 }
        averageFilter.setValue(edges, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: edges.extent), forKey: "inputExtent")
        guard let averaged = averageFilter.outputImage else { return 0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        // Color management disabled for the same reason as
        // CoreMLTileUpscaler's own context: this reads a raw intensity
        // value, not a display-ready color, so gamma/profile handling would
        // only distort the score.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(
            averaged, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil
        )
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3.0
    }
}
