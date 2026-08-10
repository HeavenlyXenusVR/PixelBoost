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

    /// A queued item can come from Photos (the original, common path) or
    /// from a directly-picked EXR file (`addEXRFiles` — EXR isn't a Photos
    /// asset, same reasoning as ContentView's separate "Import EXR"
    /// button). `.preloadedImage` decodes eagerly at selection time rather
    /// than lazily at process time — an EXR file's security-scoped Files
    /// access is simplest to use once, right when the user picks it,
    /// rather than re-opened per queue item possibly minutes later once
    /// the batch actually reaches it.
    enum ItemSource {
        case photo(PhotosPickerItem)
        case preloadedImage(UIImage, name: String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let source: ItemSource
        var status: ItemStatus = .pending
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var currentIndex: Int?

    private let provider: UpscalerProvider

    init(provider: UpscalerProvider) {
        self.provider = provider
    }

    /// Replaces every `.photo`-sourced item with the current Photos
    /// selection (matching `PhotosPicker`'s own binding semantics — it
    /// always reflects the *full* current selection, not an incremental
    /// add) — but preserves any EXR items already queued via
    /// `addEXRFiles`, since those live outside that binding entirely and
    /// a Photos re-selection shouldn't silently drop them.
    func setSelection(_ pickerItems: [PhotosPickerItem]) {
        guard !isRunning else { return }
        let preloaded = items.filter {
            if case .preloadedImage = $0.source { return true }
            return false
        }
        items = pickerItems.map { Item(source: .photo($0)) } + preloaded
    }

    /// Additive, unlike `setSelection` — each call appends. Decodes each
    /// file immediately (skipping any that fail to decode, same
    /// never-partial-output reasoning as `EXRImportService`) rather than
    /// deferring to `processItem`, so nothing needs to keep a
    /// security-scoped bookmark alive for the whole batch run.
    func addEXRFiles(_ urls: [URL]) {
        guard !isRunning else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let image = try? EXRImportService.loadImage(from: url) else { continue }
            items.append(Item(source: .preloadedImage(image, name: url.lastPathComponent)))
        }
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
            let previewImage = await Self.loadPreviewImage(items.first?.source)
            let upscaler = await provider.resolveCurrent(for: previewImage)
            BatchLiveActivityController.start(totalCount: items.count)
            for index in items.indices {
                currentIndex = index
                items[index].status = .processing
                await processItem(at: index, using: upscaler)
                BatchLiveActivityController.update(completedCount: index + 1, totalCount: items.count)
            }
            BatchLiveActivityController.end(completedCount: items.count, totalCount: items.count)
            currentIndex = nil
            isRunning = false
            if items.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                Haptics.success()
            }
        }
    }

    private func processItem(at index: Int, using upscaler: ImageUpscaling) async {
        do {
            let normalized: UIImage
            let fileSizeBytes: Int?
            let assetIdentifier: String?

            switch items[index].source {
            case .photo(let pickerItem):
                guard let data = try await pickerItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let cgImage = image.cgImage else {
                    items[index].status = .failed(UpscaleError.invalidImage.errorDescription ?? "Couldn't read this photo.")
                    return
                }
                normalized = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
                fileSizeBytes = data.count
                assetIdentifier = pickerItem.itemIdentifier
            case .preloadedImage(let image, _):
                // Already normalized by EXRDecoder (scale 1, .up) — no
                // reprocessing needed, unlike the Photos path above.
                guard image.cgImage != nil else {
                    items[index].status = .failed(UpscaleError.invalidImage.errorDescription ?? "Couldn't read this image.")
                    return
                }
                normalized = image
                fileSizeBytes = nil
                // No Photos asset to overwrite — same "adds a new asset
                // instead" fallback PhotoLibrarySaver already uses for any
                // identifier-less save (e.g. a Share Extension photo).
                assetIdentifier = nil
            }

            let outcome = await UpscaleRunner.run(
                normalized, using: upscaler, sourceFileSizeBytes: fileSizeBytes,
                denoiseAmount: provider.denoiseBeforeUpscale ? 0.5 : 0,
                sharpenAmount: provider.sharpenAmount
            ) { _ in }
            guard let result = outcome.result else {
                items[index].status = .failed(outcome.error?.localizedDescription ?? "Upscale failed.")
                return
            }
            let imageToSave = provider.watermarkEnabled
                ? Watermark.apply(
                    text: provider.watermarkText, position: provider.watermarkPosition,
                    opacity: provider.watermarkOpacity, to: result.image
                )
                : result.image
            // Note: PhotoLibrarySaver's replace path deletes-and-recreates
            // rather than truly editing in place (see its doc comment), and
            // iOS shows its own non-bypassable "Delete Photo?" confirmation
            // per asset for that — with Preserve Original off, a full
            // 20-photo batch means up to 20 of those prompts in a row.
            // Nothing batch-specific can avoid that; it's the same
            // Photos-framework confirmation Save (single-photo) triggers.
            try await PhotoLibrarySaver.save(
                imageToSave, overwriting: assetIdentifier,
                format: provider.exportFormat, quality: provider.exportQuality,
                forceNewAsset: provider.preserveOriginal, addToAlbum: provider.addToAlbumEnabled
            )
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

    private static func loadPreviewImage(_ source: ItemSource?) async -> UIImage? {
        guard let source else { return nil }
        switch source {
        case .photo(let pickerItem):
            guard let data = try? await pickerItem.loadTransferable(type: Data.self) else { return nil }
            return UIImage(data: data)
        case .preloadedImage(let image, _):
            return image
        }
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
