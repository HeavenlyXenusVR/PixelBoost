import Photos

/// Creates (once) and maintains a "PixelBoost" album in Photos — the same
/// pattern most photo-editing apps use so their output is easy to find as a
/// set instead of mixed into the Camera Roll with everything else. The
/// album's title is the app's own name, per how this was asked for.
enum PhotoAlbumService {
    private static let albumTitle = "PixelBoost"
    /// Caching the collection's `localIdentifier` avoids a title-search
    /// fetch (and, on a fresh install, a whole extra `performChanges` round
    /// trip) on every single save — only the very first save after install
    /// (or after the user deletes the album out from under the app) pays
    /// that cost.
    private static let cachedIdentifierDefaultsKey = "com.pixelboost.albumLocalIdentifier"

    /// Returns the "PixelBoost" album, creating it if this is the first
    /// time it's needed. `nil` means the album genuinely couldn't be
    /// created/found (e.g. Photos access revoked between the caller's own
    /// authorization check and this call) — callers treat that as "skip
    /// adding to an album," not as a reason to fail the save itself.
    static func ensureAlbum() async -> PHAssetCollection? {
        if let cachedID = UserDefaults.standard.string(forKey: cachedIdentifierDefaultsKey),
           let cached = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [cachedID], options: nil).firstObject {
            return cached
        }

        // Not cached (first save ever, or the cache predates this device/
        // reinstall) — search by title before creating, so reinstalling the
        // app or restoring from backup doesn't spawn a second "PixelBoost"
        // album next to the one Photos already kept.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        if let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            UserDefaults.standard.set(found.localIdentifier, forKey: cachedIdentifierDefaultsKey)
            return found
        }

        var placeholderIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                placeholderIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            return nil
        }
        guard let placeholderIdentifier,
              let created = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderIdentifier], options: nil).firstObject
        else { return nil }
        UserDefaults.standard.set(created.localIdentifier, forKey: cachedIdentifierDefaultsKey)
        return created
    }
}
