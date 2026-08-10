import ActivityKit
import Foundation

/// Shared between `PixelBoost` (starts/updates/ends the Activity from
/// `BatchUpscaleViewModel`) and `PixelBoostWidgets` (renders it) — same
/// two-targets-agree-on-one-type reasoning as `SharedPhotoBridge`/
/// `UpscaleSnapshot`, just for a Live Activity instead of a dropped file.
/// Requires `NSSupportsLiveActivities` in Info.plist (see
/// PixelBoost/Resources/Info.plist).
struct BatchUpscaleActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var completedCount: Int
        var totalCount: Int
        var currentFileName: String?
    }

    /// Static for the whole Activity's lifetime — nothing here changes
    /// between the start and end of one batch run, unlike `ContentState`.
    var startedAt: Date
}
