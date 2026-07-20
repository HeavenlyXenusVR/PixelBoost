import PhotosUI
import SwiftUI
import UIKit

/// One bundled model's full-photo result from `UpscalerViewModel.compareModels()`.
struct ModelComparisonResult: Identifiable {
    let id = UUID()
    let choice: UpscaleModelChoice
    let image: UIImage
    let sharpnessScore: Double
}

@MainActor
final class UpscalerViewModel: ObservableObject {
    @Published var sourceImage: UIImage? { didSet { imageVersion += 1 } }
    @Published var resultImage: UIImage? { didSet { imageVersion += 1 } }
    /// Bumped whenever `sourceImage`/`resultImage` change. Every editing
    /// tab is a persistent tab (see `RootView`) rather than a modal handed
    /// a fresh image each time it's opened, so each one needs some way to
    /// notice "the current photo changed while I was in the background"
    /// (e.g. Filters applied while you were sitting on the Adjust tab) —
    /// `UIImage` isn't `Equatable`, so `.onChange(of: resultImage)` isn't
    /// possible directly; tabs watch this counter instead.
    @Published private(set) var imageVersion = 0
    @Published var isUpscaling = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var savedConfirmation = false
    /// What the most recent `saveResultToPhotos()` actually did — read by
    /// `ContentView`'s confirmation alert so it can say which one happened
    /// instead of a fixed message that's wrong half the time. See
    /// `PhotoLibrarySaver.SaveOutcome`.
    @Published var lastSaveOutcome: PhotoLibrarySaver.SaveOutcome?

    /// Populated by `compareModels()` — every bundled model's full result
    /// for the current photo, for the user to look through and pick from.
    /// Non-empty is what tells `ContentView` to present the comparison
    /// gallery; clearing it (picking one, or dismissing) hides it again.
    @Published var comparisonResults: [ModelComparisonResult] = []
    @Published var isComparing = false
    @Published var comparisonProgress: Double = 0

    @Published var isRemovingBackground = false

    let provider: UpscalerProvider

    /// Captured at picker-load time from the original (still-encoded) photo
    /// data — a decoded UIImage/CGImage has no notion of "file size", so
    /// this is the only point this is ever available.
    private var sourceFileSizeBytes: Int?

    /// Also captured at picker-load time (`PhotosPickerItem.itemIdentifier`)
    /// — lets `saveResultToPhotos()` overwrite the original asset in place
    /// by default instead of always adding a duplicate. `nil` for anything
    /// the picker couldn't hand back an identifier for, in which case
    /// saving just falls back to adding a new asset as before.
    private var sourceAssetIdentifier: String?

    init(provider: UpscalerProvider) {
        self.provider = provider
    }

    func load(from item: PhotosPickerItem) async {
        errorMessage = nil
        resultImage = nil
        sourceAssetIdentifier = item.itemIdentifier
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                errorMessage = UpscaleError.invalidImage.errorDescription
                return
            }
            // Normalize to scale 1 / .up orientation up front — every tiling
            // and drawing calculation downstream assumes 1 point == 1 pixel
            // and no rotation, matching the raw cgImage's pixel grid.
            sourceImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            sourceFileSizeBytes = data.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same reset/normalize path as `load(from:)`, but for a photo handed
    /// in directly (from `SharedPhotoBridge`, i.e. the Share Extension)
    /// rather than picked from Photos. `sourceAssetIdentifier` stays nil —
    /// there's no original Photos asset to overwrite, so saving falls back
    /// to adding a new asset, same as any other identifier-less load.
    func loadSharedImage(_ image: UIImage) {
        errorMessage = nil
        resultImage = nil
        sourceAssetIdentifier = nil
        guard let cgImage = image.cgImage else { return }
        sourceImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        sourceFileSizeBytes = nil
    }

    func upscale() {
        guard let sourceImage, !isUpscaling else { return }
        isUpscaling = true
        progress = 0
        errorMessage = nil

        Task {
            // Resolve once and capture as a local `let` so this run always
            // finishes with the upscaler it started with, even if the
            // model/quality selection changes in Settings mid-flight.
            let upscaler = await provider.resolveCurrent(for: sourceImage)
            let outcome = await UpscaleRunner.run(
                sourceImage, using: upscaler, sourceFileSizeBytes: sourceFileSizeBytes,
                denoiseAmount: provider.denoiseBeforeUpscale ? 0.5 : 0,
                sharpenAmount: provider.sharpenAmount
            ) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            if let result = outcome.result {
                self.resultImage = result.image
                Haptics.success()
                if provider.autoSaveEnabled {
                    saveResultToPhotos()
                }
            } else if let error = outcome.error {
                self.errorMessage = error.localizedDescription
                Haptics.error()
            }
            self.isUpscaling = false
        }
    }

    /// Clears the current result so `resultImage ?? sourceImage` (what
    /// every tab chains onto) falls back to the untouched original photo —
    /// a single-tap way to back out of a chain of edits without re-picking
    /// the photo from scratch. `sourceImage` itself is never touched, so
    /// re-upscaling/re-editing after a revert still starts from the same
    /// original.
    func revertToOriginal() {
        guard resultImage != nil else { return }
        resultImage = nil
        Haptics.lightImpact()
    }

    /// Runs the *entire* current photo through every bundled real model in
    /// turn — not a quick test crop — and collects every result so the
    /// user can look at each full image and pick the one they like,
    /// instead of a heuristic silently choosing one for them. Each run
    /// goes through `UpscaleRunner` exactly like a normal single upscale,
    /// so every attempt (whichever ends up chosen or not) still shows up
    /// in History the same way.
    func compareModels() {
        guard let sourceImage, !isComparing, provider.quality.overlap != nil else { return }
        isComparing = true
        comparisonProgress = 0
        comparisonResults = []
        errorMessage = nil

        Task {
            let candidates = await provider.resolveAllBundled()
            guard !candidates.isEmpty else {
                errorMessage = "No bundled models available to compare."
                isComparing = false
                Haptics.error()
                return
            }

            var results: [ModelComparisonResult] = []
            for (index, candidate) in candidates.enumerated() {
                let outcome = await UpscaleRunner.run(
                    sourceImage, using: candidate.upscaler, sourceFileSizeBytes: sourceFileSizeBytes
                ) { [weak self] tileProgress in
                    Task { @MainActor in
                        self?.comparisonProgress = (Double(index) + tileProgress) / Double(candidates.count)
                    }
                }
                if let result = outcome.result {
                    results.append(ModelComparisonResult(
                        choice: candidate.choice, image: result.image,
                        sharpnessScore: UpscalerProvider.sharpnessScore(result.image)
                    ))
                }
            }

            comparisonResults = results
            isComparing = false
            if results.isEmpty {
                errorMessage = "Every model failed to produce a result."
                Haptics.error()
            } else {
                Haptics.success()
            }
        }
    }

    /// Called when the user taps "Use This" on one of `comparisonResults`.
    func pickComparisonResult(_ result: ModelComparisonResult) {
        resultImage = result.image
        comparisonResults = []
    }

    /// Cuts the subject out of the *current* image — the most recent
    /// result if there is one (an upscale, a previous cutout, a crop...),
    /// otherwise the original photo — so tools chain onto each other the
    /// same way Adjust and Crop do, rather than Cutout alone always
    /// reaching back to the untouched original. `resultImage` is reused
    /// as where the cutout lands since every downstream action (Save/
    /// Share/Copy/the compare slider) already just works with whatever
    /// image is there, transparency included.
    func removeBackground() {
        guard let workingImage = resultImage ?? sourceImage, !isRemovingBackground else { return }
        isRemovingBackground = true
        errorMessage = nil

        Task {
            do {
                let cutout = try await BackgroundRemovalService.removeBackground(from: workingImage)
                self.resultImage = cutout
                Haptics.success()
            } catch {
                self.errorMessage = error.localizedDescription
                Haptics.error()
            }
            self.isRemovingBackground = false
        }
    }

    /// Overwrites the original photo in place by default (see
    /// `PhotoLibrarySaver`) rather than adding a second, duplicate asset
    /// next to it — applies no matter which tool(s) produced `resultImage`
    /// (Upscale, Cutout, Adjust, Crop, Filters, Overlays, Erase all share
    /// this one property), since they all funnel through the same "current
    /// result" state.
    func saveResultToPhotos() {
        guard let resultImage else { return }
        let imageToSave = provider.watermarkEnabled
            ? Watermark.apply(
                text: provider.watermarkText, position: provider.watermarkPosition,
                opacity: provider.watermarkOpacity, to: resultImage
            )
            : resultImage
        Task {
            do {
                let outcome = try await PhotoLibrarySaver.save(
                    imageToSave, overwriting: sourceAssetIdentifier,
                    format: provider.exportFormat, quality: provider.exportQuality,
                    forceNewAsset: provider.preserveOriginal, addToAlbum: provider.addToAlbumEnabled
                )
                lastSaveOutcome = outcome
                // The replace is delete-original-and-create-new under the
                // hood (see PhotoLibrarySaver), not a true in-place edit —
                // sourceAssetIdentifier now points at a deleted asset, so
                // it needs to track the replacement instead, or a second
                // save later in this same session (e.g. after another
                // edit) would degrade to "asset not found" every time.
                if case .overwroteOriginal(let newAssetIdentifier) = outcome {
                    sourceAssetIdentifier = newAssetIdentifier
                }
                savedConfirmation = true
                Haptics.success()
                ActionLoggingService.log("save", detail: outcome.logDetail.merging(
                    ["model_choice": provider.modelChoice.rawValue, "had_source_asset_identifier": sourceAssetIdentifier != nil],
                    uniquingKeysWith: { _, new in new }
                ))
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
                ActionLoggingService.log("save", detail: ["outcome": "threw", "error": error.localizedDescription])
            }
        }
    }

    /// Saves every current comparison result to Photos in one action, for
    /// anyone who'd rather decide later (or keep more than one) than pick
    /// a single winner on the spot. Deliberately always adds new assets
    /// rather than going through `PhotoLibrarySaver`'s overwrite-in-place
    /// default — there's no single "the" result here to overwrite the
    /// original with, that's the whole point of saving every candidate.
    func saveAllComparisonResultsToPhotos() {
        guard !comparisonResults.isEmpty else { return }
        let images = comparisonResults.map(\.image)
        let watermarkEnabled = provider.watermarkEnabled
        let watermarkText = provider.watermarkText
        let watermarkPosition = provider.watermarkPosition
        let watermarkOpacity = provider.watermarkOpacity
        Task {
            do {
                for image in images {
                    let imageToSave = watermarkEnabled
                        ? Watermark.apply(text: watermarkText, position: watermarkPosition, opacity: watermarkOpacity, to: image)
                        : image
                    try await PhotoLibrarySaver.saveAsNewAsset(
                        imageToSave, format: provider.exportFormat, quality: provider.exportQuality,
                        addToAlbum: provider.addToAlbumEnabled
                    )
                }
                savedConfirmation = true
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
