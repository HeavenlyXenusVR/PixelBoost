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
    static func save(_ image: UIImage, overwriting assetIdentifier: String?) async throws {
        if let assetIdentifier, await overwriteOriginalAsset(assetIdentifier, with: image) {
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw UpscaleError.photoLibraryAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Requests full read/write access (not just `.addOnly` — overwriting
    /// requires reading/replacing an existing asset, which add-only access
    /// can't do) and, if granted, replaces `localIdentifier`'s content via
    /// `PHContentEditingOutput`. Returns `false` rather than throwing for
    /// every "can't overwrite" case, so the caller can silently fall back
    /// to creating a new asset instead of failing the save.
    private static func overwriteOriginalAsset(_ localIdentifier: String, with image: UIImage) async -> Bool {
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
        guard let input, let data = encodedData(for: image) else { return false }

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

    /// PNG for anything with real alpha (a Cutout result, most obviously)
    /// so transparency survives; JPEG otherwise. `creationRequestForAsset
    /// (from: UIImage)` picks this automatically, but `PHContentEditingOutput`
    /// needs raw file bytes written out by hand, so this has to be picked
    /// explicitly here.
    private static func encodedData(for image: UIImage) -> Data? {
        let alphaInfo = image.cgImage?.alphaInfo ?? .none
        let hasAlpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(alphaInfo)
        return hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.95)
    }
}
