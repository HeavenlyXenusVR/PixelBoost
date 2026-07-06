import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class UpscalerViewModel: ObservableObject {
    @Published var sourceImage: UIImage?
    @Published var resultImage: UIImage?
    @Published var isUpscaling = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var savedConfirmation = false

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
            let upscaler = await provider.resolveCurrent()
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

    private func requestPhotoLibraryAddPermission() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw UpscaleError.photoLibraryAccessDenied
        }
    }
}
