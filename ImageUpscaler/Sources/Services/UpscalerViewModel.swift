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

    /// Whether a real Core ML model is bundled — drives the "using X" label
    /// in the UI so it's obvious when the app is only falling back to
    /// plain resampling.
    let isUsingMLModel: Bool
    private let upscaler: ImageUpscaling

    /// Captured at picker-load time from the original (still-encoded) photo
    /// data — a decoded UIImage/CGImage has no notion of "file size", so
    /// this is the only point this is ever available.
    private var sourceFileSizeBytes: Int?

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
        let startedAt = Date()

        Task {
            do {
                let result = try await upscaler.upscale(sourceImage) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                self.resultImage = result.image
                logUpscale(sourceImage: sourceImage, outputImage: result.image, tileCount: result.tileCount, startedAt: startedAt, error: nil)
            } catch {
                self.errorMessage = error.localizedDescription
                logUpscale(sourceImage: sourceImage, outputImage: nil, tileCount: nil, startedAt: startedAt, error: error)
            }
            self.isUpscaling = false
        }
    }

    private func logUpscale(sourceImage: UIImage, outputImage: UIImage?, tileCount: Int?, startedAt: Date, error: Error?) {
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
            device_model: UIDevice.current.model
        )
        UpscaleLoggingService.log(entry)
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
