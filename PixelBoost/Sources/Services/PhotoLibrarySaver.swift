import ImageIO
import os
import Photos
import UIKit

/// Saves an edited photo back to the library — replacing the original
/// asset by default (identified by the `PhotosPickerItem.itemIdentifier`
/// captured when it was picked) rather than adding a second, duplicate
/// asset next to it, which used to be the only option and left the user
/// having to manually delete the leftover original every time. Falls back
/// to adding a new asset if the replace can't happen for any reason — no
/// identifier was captured, the original was deleted/moved since picking,
/// or the user declines full library access — so a save never just fails
/// outright over this.
///
/// "Replace" here means delete-the-original-and-create-a-new-asset in one
/// atomic `performChanges` transaction, not a true in-place content edit.
/// The originally-shipped approach (`PHContentEditingOutput` +
/// `PHAssetChangeRequest.contentEditingOutput`, which *is* the properly
/// sanctioned "replace this asset's content" API) reliably fails on iOS 27
/// with `PHPhotosErrorMissingResource`/`PHPhotosErrorInvalidResource`
/// depending on exactly what's attempted — every documented mitigation
/// (`canHandleAdjustmentData`, `isNetworkAccessAllowed`, `adjustmentData`)
/// was tried against real on-device failures and either did nothing or
/// made it worse; see git history on this file. Apple's own developer
/// forums have other open, unresolved reports of `performChanges` behaving
/// differently for third-party apps on iOS 26, so this looks like a
/// platform regression rather than something fixable here. Delete+recreate
/// trades true in-place editing (same localIdentifier, preserved album/
/// favorite membership) for something that actually works: exactly one
/// photo in the library afterward, not a growing pile of duplicates. iOS
/// shows its own non-bypassable "Delete Photo?" confirmation for the
/// delete half of this — expected, not a bug.
enum PhotoLibrarySaver {
    /// Why a save landed on "add a new asset" instead of overwriting —
    /// surfaced all the way to the confirmation alert (see `ContentView`)
    /// so a failed overwrite is no longer indistinguishable from a working
    /// one, or from the two cases where skipping overwrite is intentional.
    enum OverwriteFailureReason: Error {
        /// Not a failure — the user's own "Preserve Original" toggle.
        case preserveOriginalEnabled
        /// Not a failure — nothing to overwrite (e.g. an image shared in
        /// from another app rather than picked from the library).
        case noSourceAssetIdentifier
        case authorizationDenied(PHAuthorizationStatus)
        case assetNotFound
        case writeFailed(String)

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
            case .writeFailed(let message):
                return message
            }
        }

        /// Short, stable machine-readable key — for `ActionLoggingService`,
        /// where `description`'s free text (and a `writeFailed` message
        /// that can contain anything) is harder to group/filter on.
        var logKey: String {
            switch self {
            case .preserveOriginalEnabled: return "preserve_original_enabled"
            case .noSourceAssetIdentifier: return "no_source_asset_identifier"
            case .authorizationDenied(let status): return "authorization_denied_\(status.rawValue)"
            case .assetNotFound: return "asset_not_found"
            case .writeFailed: return "write_failed"
            }
        }
    }

    /// What actually happened — the caller can no longer tell replace
    /// success from a silent fallback just from "did this throw or not",
    /// since both `save` outcomes complete without throwing.
    enum SaveOutcome {
        /// `newAssetIdentifier` is the delete+recreate replacement's own
        /// identifier, distinct from whatever identifier was passed in to
        /// `save` — callers that keep re-saving the same photo across
        /// multiple edits in one session (see `UpscalerViewModel`) need to
        /// track this instead of the original, now-deleted one, or every
        /// save after the first would degrade to `.assetNotFound`.
        case overwroteOriginal(newAssetIdentifier: String)
        case addedNewAsset(reason: OverwriteFailureReason?)

        /// For `ActionLoggingService`'s "save" entries — `reason` nil means
        /// the replace fully succeeded, not "no data", so it's kept as an
        /// explicit key rather than omitted.
        var logDetail: [String: Any?] {
            switch self {
            case .overwroteOriginal:
                return ["outcome": "overwrote_original", "reason": nil, "reason_detail": nil]
            case .addedNewAsset(let reason):
                return ["outcome": "added_new_asset", "reason": reason?.logKey, "reason_detail": reason?.description]
            }
        }
    }

    private static let logger = Logger(subsystem: "com.pixelboost.ios", category: "PhotoLibrarySaver")

    /// - Parameter forceNewAsset: skips the replace path entirely and
    ///   always adds a new asset — the "Preserve Original" Settings toggle,
    ///   for anyone who wants the pre-overwrite-default behavior back.
    /// - Parameter addToAlbum: also adds the saved asset to the
    ///   "PixelBoost" album (see `PhotoAlbumService`) — the "Add to
    ///   PixelBoost Album" Settings toggle.
    @discardableResult
    static func save(
        _ image: UIImage, overwriting assetIdentifier: String?, format: ExportFormat, quality: Double,
        forceNewAsset: Bool = false, addToAlbum: Bool = true
    ) async throws -> SaveOutcome {
        if !forceNewAsset, let assetIdentifier {
            switch await replaceAsset(assetIdentifier, with: image, format: format, quality: quality, addToAlbum: addToAlbum) {
            case .success(let newAssetIdentifier):
                return .overwroteOriginal(newAssetIdentifier: newAssetIdentifier)
            case .failure(let reason):
                try await saveAsNewAsset(image, format: format, quality: quality, addToAlbum: addToAlbum)
                return .addedNewAsset(reason: reason)
            }
        }

        try await saveAsNewAsset(image, format: format, quality: quality, addToAlbum: addToAlbum)
        return .addedNewAsset(reason: forceNewAsset ? .preserveOriginalEnabled : .noSourceAssetIdentifier)
    }

    /// Always adds a new asset rather than overwriting — used both as
    /// `save`'s fallback and directly by "Save All" on a Compare Models
    /// grid, which has no single result there to overwrite the original
    /// with (that's the whole point of keeping every candidate).
    static func saveAsNewAsset(_ image: UIImage, format: ExportFormat, quality: Double, addToAlbum: Bool = true) async throws {
        guard let data = encodedData(for: image, format: format, quality: quality) else {
            throw UpscaleError.invalidImage
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw UpscaleError.photoLibraryAccessDenied
        }
        // Resolved before entering performChanges since ensureAlbum() is
        // itself async (it may need its own performChanges round trip to
        // create the album on first use) and performChanges's own change
        // block must run synchronously.
        let album = addToAlbum ? await PhotoAlbumService.ensureAlbum() : nil
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            if let album, let placeholder = request.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    /// Requests full read/write access (not just `.addOnly` — deleting the
    /// original requires it) and, if granted, creates a new asset from
    /// `image` and deletes `localIdentifier`'s asset in one atomic
    /// `performChanges` transaction — see this file's top-level doc comment
    /// for why this replaces the originally-shipped `PHContentEditingOutput`
    /// approach. Returns the new asset's identifier on success, or the
    /// specific failure reason (including the user declining iOS's
    /// mandatory delete confirmation) rather than throwing, so the caller
    /// can fall back to creating a new asset without deleting anything
    /// instead of failing the save outright.
    private static func replaceAsset(
        _ localIdentifier: String, with image: UIImage, format: ExportFormat, quality: Double, addToAlbum: Bool = true
    ) async -> Result<String, OverwriteFailureReason> {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            logger.error("Replace skipped: readWrite authorization status is \(status.rawValue, privacy: .public)")
            return .failure(.authorizationDenied(status))
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            logger.error("Replace skipped: no PHAsset found for identifier (asset moved/deleted, or not visible under Limited Library access)")
            return .failure(.assetNotFound)
        }

        guard let data = encodedData(for: image, format: format, quality: quality) else {
            return .failure(.writeFailed("couldn't encode the edited image"))
        }

        let album = addToAlbum ? await PhotoAlbumService.ensureAlbum() : nil
        do {
            var newIdentifier: String?
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: data, options: nil)
                let placeholder = creationRequest.placeholderForCreatedAsset
                newIdentifier = placeholder?.localIdentifier
                if let album, let placeholder {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            guard let newIdentifier else {
                return .failure(.writeFailed("no identifier for the newly created asset"))
            }
            return .success(newIdentifier)
        } catch {
            // The full NSError, not just localizedDescription — PHPhotosError
            // ("PHPhotosErrorDomain error NNNN") carries most of its actual
            // diagnostic detail in userInfo, which localizedDescription
            // alone drops on the floor. Also where a user declining iOS's
            // own delete confirmation surfaces — performChanges is atomic,
            // so declining rolls back the creation half too, same as any
            // other failure here.
            let nsError = error as NSError
            let detail = "\(error.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)]"
            logger.error("Replace failed: \(detail, privacy: .public)")
            return .failure(.writeFailed(detail))
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
