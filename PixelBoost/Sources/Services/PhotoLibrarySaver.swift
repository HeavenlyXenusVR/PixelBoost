import ImageIO
import os
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
    /// Why a save landed on "add a new asset" instead of overwriting —
    /// surfaced all the way to the confirmation alert (see `ContentView`)
    /// so a failed overwrite is no longer indistinguishable from a working
    /// one, or from the two cases where skipping overwrite is intentional.
    enum OverwriteFailureReason {
        /// Not a failure — the user's own "Preserve Original" toggle.
        case preserveOriginalEnabled
        /// Not a failure — nothing to overwrite (e.g. an image shared in
        /// from another app rather than picked from the library).
        case noSourceAssetIdentifier
        case authorizationDenied(PHAuthorizationStatus)
        case assetNotFound
        case contentEditingInputUnavailable
        case writeFailed(String)

        /// `false` for the two intentional/expected cases above.
        var isFailure: Bool {
            switch self {
            case .preserveOriginalEnabled, .noSourceAssetIdentifier: return false
            default: return true
            }
        }

        var description: String {
            switch self {
            case .preserveOriginalEnabled:
                return "Preserve Original is on in Settings"
            case .noSourceAssetIdentifier:
                return "this photo wasn't loaded from your library"
            case .authorizationDenied(let status):
                return "Photos access is \(status.rawValue) (not full/limited read-write)"
            case .assetNotFound:
                return "the original couldn't be found in your library (moved, deleted, or not visible to this app)"
            case .contentEditingInputUnavailable:
                return "the original photo's data couldn't be read"
            case .writeFailed(let message):
                return message
            }
        }
    }

    /// What actually happened — the caller can no longer tell overwrite
    /// success from a silent fallback just from "did this throw or not",
    /// since both `save` outcomes complete without throwing.
    enum SaveOutcome {
        case overwroteOriginal
        case addedNewAsset(reason: OverwriteFailureReason?)
    }

    private static let logger = Logger(subsystem: "com.pixelboost.ios", category: "PhotoLibrarySaver")

    /// - Parameter forceNewAsset: skips the overwrite path entirely and
    ///   always adds a new asset — the "Preserve Original" Settings toggle,
    ///   for anyone who wants the pre-overwrite-default behavior back.
    @discardableResult
    static func save(
        _ image: UIImage, overwriting assetIdentifier: String?, format: ExportFormat, quality: Double,
        forceNewAsset: Bool = false
    ) async throws -> SaveOutcome {
        let reason: OverwriteFailureReason?
        if forceNewAsset {
            reason = .preserveOriginalEnabled
        } else if let assetIdentifier {
            reason = await overwriteOriginalAsset(assetIdentifier, with: image, format: format, quality: quality)
        } else {
            reason = .noSourceAssetIdentifier
        }

        guard let reason else { return .overwroteOriginal }
        try await saveAsNewAsset(image, format: format, quality: quality)
        return .addedNewAsset(reason: reason)
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
    /// `PHContentEditingOutput`. Returns `nil` on success, or the specific
    /// reason it couldn't rather than throwing, so the caller can fall back
    /// to creating a new asset instead of failing the save outright while
    /// still reporting why to `SaveOutcome`.
    private static func overwriteOriginalAsset(
        _ localIdentifier: String, with image: UIImage, format: ExportFormat, quality: Double
    ) async -> OverwriteFailureReason? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            logger.error("Overwrite skipped: readWrite authorization status is \(status.rawValue, privacy: .public)")
            return .authorizationDenied(status)
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            logger.error("Overwrite skipped: no PHAsset found for identifier (asset moved/deleted, or not visible under Limited Library access)")
            return .assetNotFound
        }

        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: nil) { input, info in
                if input == nil {
                    logger.error("Overwrite skipped: requestContentEditingInput returned nil, info: \(String(describing: info), privacy: .public)")
                }
                continuation.resume(returning: input)
            }
        }
        guard let input else { return .contentEditingInputUnavailable }
        guard let data = encodedData(for: image, format: format, quality: quality) else {
            return .writeFailed("couldn't encode the edited image")
        }

        let output = PHContentEditingOutput(contentEditingInput: input)
        do {
            try data.write(to: output.renderedContentURL, options: .atomic)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.contentEditingOutput = output
            }
            return nil
        } catch {
            logger.error("Overwrite failed: \(error.localizedDescription, privacy: .public)")
            return .writeFailed(error.localizedDescription)
        }
    }

    /// Encodes `image` per the user's chosen export format/quality
    /// (Settings). `.auto` keeps the original heuristic — PNG for real
    /// alpha (a Cutout result), JPEG otherwise — since forcing a lossy
    /// format on something with transparency would silently flatten it.
    private static func encodedData(for image: UIImage, format: ExportFormat, quality: Double) -> Data? {
        switch format {
        case .auto:
            return image.hasAlphaChannel ? image.pngData() : image.jpegData(compressionQuality: quality)
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
