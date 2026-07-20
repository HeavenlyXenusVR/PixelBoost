import CoreImage
import Foundation
import UIKit

/// Which bundled Core ML model to use. Each case's `modelName` must match a
/// compiled model in Models/ (see Models/README.md) — resolving a choice
/// whose model isn't actually bundled falls back to `LanczosUpscaler`
/// rather than throwing, same as the original single-model behavior.
/// `.textDocument` isn't bundled yet (no matching `.mlmodelc`) — it exists
/// so the picker honestly shows where the model lineup is headed,
/// degrading the same "not bundled" way any missing model already does
/// rather than hiding the option entirely.
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
        case .lowLight: return "Fast & Clean"
        case .textDocument: return "Text & Documents"
        }
    }

    var modelName: String {
        switch self {
        case .auto: return ""
        case .generalPhoto: return "RealESRGAN"
        case .anime: return "RealESRGANAnime"
        // RealESRNet_x4plus: same RRDBNet architecture and training data as
        // RealESRGAN, but trained with only L1 loss (no GAN) — noticeably
        // smoother, less prone to the over-sharpened/ringing artifacts GAN
        // training can put on skin and other soft gradients, which is why
        // it's the Portrait pick rather than the general-purpose one.
        case .portrait: return "RealESRNet"
        // realesr-general-x4v3: a much smaller/faster SRVGGNetCompact
        // architecture (32 conv layers vs RRDBNet's 23 dense residual
        // blocks) built for everyday real-world photos — quicker per tile
        // with a cleaner, lower-artifact result than the heavier models.
        case .lowLight: return "RealESRGeneralV3"
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

/// Final output size, as a multiple of the source photo's own dimensions.
/// Independent of which model runs — see `ScaledOutputUpscaler` for how a
/// model fixed at a 4x native scale still delivers 2x/3x output.
enum UpscaleFactor: Int, CaseIterable, Identifiable {
    case x2 = 2
    case x3 = 3
    case x4 = 4

    var id: Int { rawValue }
    var displayName: String { "\(rawValue)×" }
}

/// File format saved results are encoded as. `.auto` keeps the original
/// heuristic (PNG for anything with real alpha — a Cutout result, most
/// obviously — JPEG otherwise) rather than forcing one format regardless
/// of transparency. See `PhotoLibrarySaver`.
enum ExportFormat: String, CaseIterable, Identifiable {
    case auto
    case heic
    case jpeg
    case png

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        }
    }

    /// PNG is lossless — there's no quality dial to show for it.
    var usesQuality: Bool { self != .png }
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
    private static let scaleFactorDefaultsKey = "com.pixelboost.scaleFactor"
    private static let exportFormatDefaultsKey = "com.pixelboost.exportFormat"
    private static let exportQualityDefaultsKey = "com.pixelboost.exportQuality"
    private static let denoiseBeforeUpscaleDefaultsKey = "com.pixelboost.denoiseBeforeUpscale"
    private static let sharpenAmountDefaultsKey = "com.pixelboost.sharpenAmount"
    private static let autoSaveEnabledDefaultsKey = "com.pixelboost.autoSaveEnabled"
    private static let preserveOriginalDefaultsKey = "com.pixelboost.preserveOriginal"
    private static let addToAlbumEnabledDefaultsKey = "com.pixelboost.addToAlbumEnabled"
    private static let watermarkEnabledDefaultsKey = "com.pixelboost.watermarkEnabled"
    private static let watermarkTextDefaultsKey = "com.pixelboost.watermarkText"
    private static let watermarkPositionDefaultsKey = "com.pixelboost.watermarkPosition"
    private static let watermarkOpacityDefaultsKey = "com.pixelboost.watermarkOpacity"
    private static let defaultTabDefaultsKey = "com.pixelboost.defaultTab"
    private static let accentThemeDefaultsKey = "com.pixelboost.accentTheme"

    /// Side of the test region (before the model's own scale factor) run
    /// through each candidate during `BatchUpscaleViewModel`'s unattended
    /// auto-pick. Big enough to span a handful of `CoreMLTileUpscaler`
    /// tiles — one flat 128x128 crop wouldn't reliably tell two models
    /// apart — small enough that testing every bundled candidate still
    /// finishes in a fraction of the real upscale's time.
    private static let autoTestRegionSize = 256

    @Published var modelChoice: UpscaleModelChoice {
        didSet { UserDefaults.standard.set(modelChoice.rawValue, forKey: Self.modelChoiceDefaultsKey) }
    }
    @Published var quality: UpscaleQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityDefaultsKey) }
    }
    @Published var scaleFactor: UpscaleFactor {
        didSet { UserDefaults.standard.set(scaleFactor.rawValue, forKey: Self.scaleFactorDefaultsKey) }
    }
    @Published var exportFormat: ExportFormat {
        didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: Self.exportFormatDefaultsKey) }
    }
    /// JPEG/HEIC compression quality, 0...1. Meaningless for `.png`
    /// (lossless) — kept as a single shared value rather than one per
    /// format since a user picking between HEIC and JPEG almost certainly
    /// wants "the same tradeoff," not to retune it per format.
    @Published var exportQuality: Double {
        didSet { UserDefaults.standard.set(exportQuality, forKey: Self.exportQualityDefaultsKey) }
    }
    /// Runs `RestoreService.denoise` on the source photo before it's handed
    /// to the upscaler — helps a model avoid amplifying sensor noise into
    /// upscaled speckle on grainy/low-light source photos. Off by default
    /// since it softens fine detail slightly on already-clean photos.
    @Published var denoiseBeforeUpscale: Bool {
        didSet { UserDefaults.standard.set(denoiseBeforeUpscale, forKey: Self.denoiseBeforeUpscaleDefaultsKey) }
    }
    /// 0...1, applied via `PostSharpen` right after the upscale finishes
    /// (on the final, already-upscaled image). 0 is off — a model's own
    /// output is usually sharp enough on its own; this is for anyone who
    /// wants an extra edge-crispness pass on top, same idea as Restore's
    /// face-sharpen but applied over the whole frame.
    @Published var sharpenAmount: Double {
        didSet { UserDefaults.standard.set(sharpenAmount, forKey: Self.sharpenAmountDefaultsKey) }
    }
    /// When on, a successful single-photo upscale calls
    /// `UpscalerViewModel.saveResultToPhotos()` on its own right after
    /// finishing — for anyone who always taps Save anyway. Doesn't apply to
    /// Batch (already saves every item as it completes) or Compare Models
    /// (nothing to save until a candidate's picked).
    @Published var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: Self.autoSaveEnabledDefaultsKey) }
    }
    /// When on, every save (single photo and Batch) always adds a new
    /// Photos asset instead of overwriting the original in place — the
    /// opt-out for anyone who wants the pre-overwrite-default behavior
    /// back. See `PhotoLibrarySaver`.
    @Published var preserveOriginal: Bool {
        didSet { UserDefaults.standard.set(preserveOriginal, forKey: Self.preserveOriginalDefaultsKey) }
    }
    /// When on (the default), every saved photo is also added to a
    /// "PixelBoost" album in Photos — created on first use via
    /// `PhotoAlbumService` — so upscaled/edited photos are easy to find as a
    /// set instead of mixed into the Camera Roll with everything else.
    @Published var addToAlbumEnabled: Bool {
        didSet { UserDefaults.standard.set(addToAlbumEnabled, forKey: Self.addToAlbumEnabledDefaultsKey) }
    }
    @Published var watermarkEnabled: Bool {
        didSet { UserDefaults.standard.set(watermarkEnabled, forKey: Self.watermarkEnabledDefaultsKey) }
    }
    @Published var watermarkText: String {
        didSet { UserDefaults.standard.set(watermarkText, forKey: Self.watermarkTextDefaultsKey) }
    }
    @Published var watermarkPosition: WatermarkPosition {
        didSet { UserDefaults.standard.set(watermarkPosition.rawValue, forKey: Self.watermarkPositionDefaultsKey) }
    }
    @Published var watermarkOpacity: Double {
        didSet { UserDefaults.standard.set(watermarkOpacity, forKey: Self.watermarkOpacityDefaultsKey) }
    }
    /// Which tab `RootView` selects on launch. Read once, at app start —
    /// see `AccentTheme`'s doc comment for why settings read only once at
    /// launch are the safe pattern here (every tab stays mounted for the
    /// app's whole lifetime, so there's no later point this would "just
    /// re-apply" on its own without extra plumbing).
    @Published var defaultTab: AppTab {
        didSet { UserDefaults.standard.set(defaultTab.rawValue, forKey: Self.defaultTabDefaultsKey) }
    }
    /// Persisted immediately on change, but only actually read by
    /// `PBColor` once, at first access — see `AccentTheme`. Settings shows
    /// the current selection either way (so the picker itself stays
    /// accurate), with a footnote explaining the next-launch delay.
    @Published var accentTheme: AccentTheme {
        didSet { UserDefaults.standard.set(accentTheme.rawValue, forKey: Self.accentThemeDefaultsKey) }
    }
    /// True while a not-yet-cached model is being loaded — lets the UI show
    /// a spinner instead of silently hitching on the first use of a given
    /// model.
    @Published private(set) var isLoadingModel = false
    /// True while `BatchUpscaleViewModel`'s unattended auto-pick is running
    /// its candidate models over the test region — a separate flag from
    /// `isLoadingModel` since it can span loading *multiple* models, not
    /// just one.
    @Published private(set) var isTestingModels = false
    /// Which model batch's auto-pick last landed on, so Settings can show
    /// "Last auto pick" instead of leaving the choice invisible. The
    /// interactive main screen no longer auto-picks silently — see
    /// `UpscalerViewModel.compareModels()` — so this only ever reflects a
    /// batch run.
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
        let storedScale = UserDefaults.standard.object(forKey: Self.scaleFactorDefaultsKey) as? Int
        scaleFactor = storedScale.flatMap(UpscaleFactor.init(rawValue:)) ?? .x4
        exportFormat = UserDefaults.standard.string(forKey: Self.exportFormatDefaultsKey)
            .flatMap(ExportFormat.init(rawValue:)) ?? .auto
        let storedQuality = UserDefaults.standard.object(forKey: Self.exportQualityDefaultsKey) as? Double
        exportQuality = storedQuality ?? 0.9
        denoiseBeforeUpscale = UserDefaults.standard.bool(forKey: Self.denoiseBeforeUpscaleDefaultsKey)
        let storedSharpen = UserDefaults.standard.object(forKey: Self.sharpenAmountDefaultsKey) as? Double
        sharpenAmount = storedSharpen ?? 0
        autoSaveEnabled = UserDefaults.standard.bool(forKey: Self.autoSaveEnabledDefaultsKey)
        preserveOriginal = UserDefaults.standard.bool(forKey: Self.preserveOriginalDefaultsKey)
        addToAlbumEnabled = (UserDefaults.standard.object(forKey: Self.addToAlbumEnabledDefaultsKey) as? Bool) ?? true
        watermarkEnabled = UserDefaults.standard.bool(forKey: Self.watermarkEnabledDefaultsKey)
        watermarkText = UserDefaults.standard.string(forKey: Self.watermarkTextDefaultsKey) ?? ""
        watermarkPosition = UserDefaults.standard.string(forKey: Self.watermarkPositionDefaultsKey)
            .flatMap(WatermarkPosition.init(rawValue:)) ?? .bottomRight
        let storedWatermarkOpacity = UserDefaults.standard.object(forKey: Self.watermarkOpacityDefaultsKey) as? Double
        watermarkOpacity = storedWatermarkOpacity ?? 0.7
        defaultTab = UserDefaults.standard.string(forKey: Self.defaultTabDefaultsKey)
            .flatMap(AppTab.init(rawValue:)) ?? .home
        accentTheme = UserDefaults.standard.string(forKey: Self.accentThemeDefaultsKey)
            .flatMap(AccentTheme.init(rawValue:)) ?? .blue
    }

    /// Resolves the upscaler for the *current* model/quality/scale
    /// selection. Call again after any of them changes. Used by the
    /// interactive single-image flow when a specific model (not `.auto`)
    /// is picked, and by `BatchUpscaleViewModel` regardless of model
    /// choice — batch has no one present to pick from a comparison per
    /// photo, so `.auto` there still resolves via the same unattended
    /// heuristic pick `.auto` itself used before Compare All existed.
    /// `sourceImage`, when provided, is used only for that unattended
    /// pick — `nil`-safe (falls back to the first bundled candidate)
    /// since not every caller has an image ready up front.
    func resolveCurrent(for sourceImage: UIImage? = nil) async -> ImageUpscaling {
        guard let overlap = quality.overlap else {
            return LanczosUpscaler(scaleFactor: Double(scaleFactor.rawValue))
        }

        let choice: UpscaleModelChoice
        if modelChoice == .auto {
            choice = await autoSelectModel(for: sourceImage, overlap: overlap) ?? .generalPhoto
            lastAutoSelectedModel = choice
        } else {
            choice = modelChoice
        }

        guard let base = await resolvedModel(for: choice, overlap: overlap) else {
            return LanczosUpscaler(scaleFactor: Double(scaleFactor.rawValue))
        }
        return ScaledOutputUpscaler(base: base, nativeScale: 4, targetScale: scaleFactor.rawValue)
    }

    /// Resolves every *actually bundled* real model at once, each wrapped
    /// to the current scale selection — the interactive counterpart to
    /// `resolveCurrent`'s single pick, for `UpscalerViewModel.compareModels()`
    /// to run the full photo through every one of them and let the user
    /// choose by eye instead of a heuristic choosing for them.
    func resolveAllBundled() async -> [(choice: UpscaleModelChoice, upscaler: ImageUpscaling)] {
        guard let overlap = quality.overlap else { return [] }
        let candidates = UpscaleModelChoice.allCases.filter { $0 != .auto && $0.isBundled }

        var resolved: [(UpscaleModelChoice, ImageUpscaling)] = []
        for candidate in candidates {
            guard let base = await resolvedModel(for: candidate, overlap: overlap) else { continue }
            resolved.append((candidate, ScaledOutputUpscaler(base: base, nativeScale: 4, targetScale: scaleFactor.rawValue)))
        }
        return resolved
    }

    /// Loads (or returns the already-cached) `CoreMLTileUpscaler` for
    /// `choice`, or `nil` if it isn't bundled / fails to load — every
    /// caller in this file that needs one concrete model goes through
    /// here so the cache stays a single source of truth.
    private func resolvedModel(for choice: UpscaleModelChoice, overlap: Int) async -> CoreMLTileUpscaler? {
        if let cached = cache[choice.modelName] {
            cached.updateOverlap(overlap)
            return cached
        }
        guard let loaded = await loadUpscaler(named: choice.modelName, overlap: overlap) else { return nil }
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
    /// and keeps whichever produced the sharpest, most-detailed result —
    /// used only by `BatchUpscaleViewModel`, where nobody is present to
    /// pick per photo across a queue of up to 20. Returns `nil` (caller
    /// falls back to `.generalPhoto`) if there's no image to test against
    /// or fewer than two real candidates to choose between.
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
            guard let upscaler = await resolvedModel(for: candidate, overlap: overlap) else { continue }
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
    /// Not `private` — `UpscalerViewModel.compareModels()` reuses it to
    /// show a sharpness figure alongside each full comparison result too.
    static func sharpnessScore(_ image: UIImage) -> Double {
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
