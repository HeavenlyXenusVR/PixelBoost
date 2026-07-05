import Photos
import PhotosUI
import SwiftUI

@MainActor
final class UpscalerViewModel: ObservableObject {
    @Published var sourceImage: UIImage?
    @Published var resultImage: UIImage?
    @Published var isUpscaling = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var savedConfirmation = false

    /// Whether a real Core ML model is bundled — drives the "using X" label
    /// in the UI so it's obvious when the app is only falling back to
    /// plain resampling.
    let isUsingMLModel: Bool
    private let upscaler: ImageUpscaling

    init() {
        if let mlUpscaler = try? CoreMLTileUpscaler() {
            self.upscaler = mlUpscaler
            self.isUsingMLModel = true
        } else {
            self.upscaler = LanczosUpscaler()
            self.isUsingMLModel = false
        }
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
            do {
                let result = try await upscaler.upscale(sourceImage) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                self.resultImage = result
            } catch {
                self.errorMessage = error.localizedDescription
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
            } catch {
                errorMessage = error.localizedDescription
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
