import Photos
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
    @Published var sourceImage: UIImage?
    @Published var resultImage: UIImage?
    @Published var isUpscaling = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var savedConfirmation = false

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

    init(provider: UpscalerProvider) {
        self.provider = provider
    }

    func load(from item: PhotosPickerItem) async {
        errorMessage = nil
        resultImage = nil
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
                sourceImage, using: upscaler, sourceFileSizeBytes: sourceFileSizeBytes
            ) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            if let result = outcome.result {
                self.resultImage = result.image
                Haptics.success()
            } else if let error = outcome.error {
                self.errorMessage = error.localizedDescription
                Haptics.error()
            }
            self.isUpscaling = false
        }
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

    /// Cuts the subject out of the *original* photo (not whatever's
    /// currently in `resultImage`) — a standalone tool alongside Upscale/
    /// Compare Models, not a step chained onto them. `resultImage` is
    /// reused as where the cutout lands since every downstream action
    /// (Save/Share/Copy/the compare slider) already just works with
    /// whatever image is there, transparency included.
    func removeBackground() {
        guard let sourceImage, !isRemovingBackground else { return }
        isRemovingBackground = true
        errorMessage = nil

        Task {
            do {
                let cutout = try await BackgroundRemovalService.removeBackground(from: sourceImage)
                self.resultImage = cutout
                Haptics.success()
            } catch {
                self.errorMessage = error.localizedDescription
                Haptics.error()
            }
            self.isRemovingBackground = false
        }
    }

    func saveResultToPhotos() {
        guard let resultImage else { return }
        Task {
            do {
                try await requestPhotoLibraryAddPermission()
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: resultImage)
                }
                savedConfirmation = true
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    /// Saves every current comparison result to Photos in one action, for
    /// anyone who'd rather decide later (or keep more than one) than pick
    /// a single winner on the spot.
    func saveAllComparisonResultsToPhotos() {
        guard !comparisonResults.isEmpty else { return }
        let images = comparisonResults.map(\.image)
        Task {
            do {
                try await requestPhotoLibraryAddPermission()
                try await PHPhotoLibrary.shared().performChanges {
                    for image in images {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }
                savedConfirmation = true
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func requestPhotoLibraryAddPermission() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw UpscaleError.photoLibraryAccessDenied
        }
    }
}
