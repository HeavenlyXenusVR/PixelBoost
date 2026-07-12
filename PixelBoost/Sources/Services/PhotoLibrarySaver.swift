import ImageIO
import Photos
import UIKit

/// Saves an edited photo back to the library — overwriting the original
/// asset in place by default (identified by the `PhotosPickerItem.
/// itemIdentifier` captured when it was picked) rather than adding a
/// second, duplicate asset next to it, which used to be the only option
/// and left the user having to manually delete the leftover original
/// every time. Falls back to adding a new asset if overwriting isn't
/// possible for any reason — no identifier was captured, the original was
/// deleted/moved since picking, or the user declines full library access
/// for the overwrite path — so a save never just fails outright over this.
enum PhotoLibrarySaver {
    static func save(_ image: UIImage, overwriting assetIdentifier: String?, format: ExportFormat, quality: Double) async throws {
        if let assetIdentifier, await overwriteOriginalAsset(assetIdentifier, with: image, format: format, quality: quality) {
            return
        }
        try await saveAsNewAsset(image, format: format, quality: quality)
    }

    /// Always adds a new asset rather than overwriting — used both as
    /// `save`'s fallback and directly by "Save All" on a Compare Models
    /// grid, which has no single result there to overwrite the original
    /// with (that's the whole point of keeping every candidate).
    static func saveAsNewAsset(_ image: UIImage, format: ExportFormat, quality: Double) async throws {
        guard let data = encodedData(for: image, format: format, quality: quality) else {
            throw UpscaleError.invalidImage
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw UpscaleError.photoLibraryAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    /// Requests full read/write access (not just `.addOnly` — overwriting
    /// requires reading/replacing an existing asset, which add-only access
    /// can't do) and, if granted, replaces `localIdentifier`'s content via
    /// `PHContentEditingOutput`. Returns `false` rather than throwing for
    /// every "can't overwrite" case, so the caller can silently fall back
    /// to creating a new asset instead of failing the save.
    private static func overwriteOriginalAsset(
        _ localIdentifier: String, with image: UIImage, format: ExportFormat, quality: Double
    ) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return false
        }

        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: nil) { input, _ in
                continuation.resume(returning: input)
            }
        }
        guard let input, let data = encodedData(for: image, format: format, quality: quality) else { return false }

        let output = PHContentEditingOutput(contentEditingInput: input)
        do {
            try data.write(to: output.renderedContentURL, options: .atomic)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.contentEditingOutput = output
            }
            return true
        } catch {
            return false
        }
    }

    /// Encodes `image` per the user's chosen export format/quality
    /// (Settings). `.auto` keeps the original heuristic — PNG for real
    /// alpha (a Cutout result), JPEG otherwise — since forcing a lossy
    /// format on something with transparency would silently flatten it.
    private static func encodedData(for image: UIImage, format: ExportFormat, quality: Double) -> Data? {
        switch format {
        case .auto:
            return hasAlpha(image) ? image.pngData() : image.jpegData(compressionQuality: quality)
        case .png:
            return image.pngData()
        case .jpeg:
            return image.jpegData(compressionQuality: quality)
        case .heic:
            // UIImage has no built-in HEIC encoder (unlike pngData()/
            // jpegData(compressionQuality:)) — falls back to JPEG if HEIC
            // encoding isn't available (e.g. an older device/simulator)
            // rather than failing the save outright.
            return heicData(for: image, quality: quality) ?? image.jpegData(compressionQuality: quality)
        }
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        let alphaInfo = image.cgImage?.alphaInfo ?? .none
        return ![.none, .noneSkipLast, .noneSkipFirst].contains(alphaInfo)
    }

    private static func heicData(for image: UIImage, quality: Double) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
