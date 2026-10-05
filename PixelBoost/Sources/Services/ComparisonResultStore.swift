import UIKit

/// Holds a Compare Models sweep's full-resolution candidate results on disk
/// instead of in memory.
///
/// A sweep runs every bundled model over the full photo and used to keep
/// all N finished `UIImage`s alive at once in `comparisonResults`, for a
/// set the user is about to discard all but one of. Live telemetry made
/// the cost unmistakable: peak footprint rose monotonically with candidate
/// index — 153, 265, 325, 434, 513, 618, 673, 754 MB across an 8-model
/// sweep, roughly +86 MB per candidate and independent of which model ran.
/// That pattern is accumulation, not per-model cost. Alongside it: four
/// memory warnings (up to 2,105 MB), thermal climbing nominal -> fair ->
/// serious, and the output memory guard capping half of all compare runs.
///
/// So each candidate is written out as soon as it finishes and dropped from
/// memory, leaving only a display-sized preview for the grid. The chosen
/// one is read back at full resolution on pick.
///
/// PNG, not JPEG: a candidate the user keeps becomes their actual result,
/// so these have to stay lossless. The encode is real work (order of a
/// second for a 20MP result) but it buys back hundreds of megabytes, and
/// a sweep that OOMs or gets its output capped costs far more than that.
///
/// Caches directory, not Documents: these are reconstructible scratch files
/// and the system may evict them under storage pressure, which is exactly
/// the right behaviour for them.
enum ComparisonResultStore {
    private static let folderName = "ComparisonResults"

    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = caches.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Writes `image` and returns where it landed, or `nil` if it couldn't
    /// be written — the caller falls back to holding the image in memory,
    /// which is the old behavior and still better than losing the result.
    static func write(_ image: UIImage, id: UUID) -> URL? {
        guard let directory, let data = image.pngData() else { return nil }
        let url = directory.appendingPathComponent("\(id.uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("ComparisonResultStore: write failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Reads one candidate back at full resolution. Call off the main actor
    /// — decoding a 20MP PNG is not a main-thread operation.
    static func load(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Deletes every spilled file. Called when a sweep starts, once a pick
    /// has been read back, and at launch — a crash or a force-quit mid-sweep
    /// would otherwise leave these behind, and nothing else ever reads them.
    static func clear() {
        guard let directory,
              let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
