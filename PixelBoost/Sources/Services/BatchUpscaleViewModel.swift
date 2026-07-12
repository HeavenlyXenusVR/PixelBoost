import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class BatchUpscaleViewModel: ObservableObject {
    enum ItemStatus {
        case pending
        case processing
        case done(thumbnail: UIImage)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let pickerItem: PhotosPickerItem
        var status: ItemStatus = .pending
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var currentIndex: Int?

    private let provider: UpscalerProvider

    init(provider: UpscalerProvider) {
        self.provider = provider
    }

    func setSelection(_ pickerItems: [PhotosPickerItem]) {
        guard !isRunning else { return }
        items = pickerItems.map { Item(pickerItem: $0) }
    }

    func runAll() {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        Task {
            // Resolved once for the whole batch — same in-flight-safety
            // reasoning as UpscalerViewModel.upscale(): a model/quality
            // change in Settings mid-batch shouldn't switch the upscaler
            // out from under items still queued. If `.auto` is selected,
            // its candidate test runs against the first item only (loaded
            // here, then reloaded by processItem(at:) — a small duplicated
            // fetch, not a network call, in exchange for not threading a
            // preloaded image through the whole queue for one case).
            let previewImage = await Self.loadPreviewImage(items.first?.pickerItem)
            let upscaler = await provider.resolveCurrent(for: previewImage)
            for index in items.indices {
                currentIndex = index
                items[index].status = .processing
                await processItem(at: index, using: upscaler)
            }
            currentIndex = nil
            isRunning = false
            if items.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                Haptics.success()
            }
        }
    }

    private func processItem(at index: Int, using upscaler: ImageUpscaling) async {
        do {
            guard let data = try await items[index].pickerItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                items[index].status = .failed(UpscaleError.invalidImage.errorDescription ?? "Couldn't read this photo.")
                return
            }
            let normalized = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            let outcome = await UpscaleRunner.run(
                normalized, using: upscaler, sourceFileSizeBytes: data.count
            ) { _ in }
            guard let result = outcome.result else {
                items[index].status = .failed(outcome.error?.localizedDescription ?? "Upscale failed.")
                return
            }
            try await PhotoLibrarySaver.save(result.image, overwriting: items[index].pickerItem.itemIdentifier)
            // Keep only a small thumbnail, not the full-resolution result —
            // a 4000x4000 output is ~64MB uncompressed, and holding N of
            // those in memory across a whole queued batch (rather than
            // saving-and-releasing each as it completes) is a real Jetsam
            // risk on older/lower-RAM devices. The result is already saved
            // to Photos above by this point.
            items[index].status = .done(thumbnail: Self.thumbnail(of: result.image))
        } catch {
            items[index].status = .failed(error.localizedDescription)
        }
    }

    private static func loadPreviewImage(_ pickerItem: PhotosPickerItem?) async -> UIImage? {
        guard let pickerItem,
              let data = try? await pickerItem.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: data)
    }

    private static func thumbnail(of image: UIImage, maxDimension: CGFloat = 120) -> UIImage {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
