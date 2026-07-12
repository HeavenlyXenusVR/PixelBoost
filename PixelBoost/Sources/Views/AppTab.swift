import Foundation

/// Every top-level destination in the app, in bottom-bar order. There are
/// more than the ~5 iOS puts in a native `TabView` before collapsing the
/// rest into an auto-generated "More" list, so `RootView` builds its own
/// horizontally scrollable bar instead of using `TabView`.
enum AppTab: String, CaseIterable, Identifiable {
    case home, cutout, enhance, adjust, crop, filters, overlays, erase, batch, cloud, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Upscale"
        case .cutout: return "Cutout"
        case .enhance: return "Enhance"
        case .adjust: return "Adjust"
        case .crop: return "Crop"
        case .filters: return "Filters"
        case .overlays: return "Overlays"
        case .erase: return "Erase"
        case .batch: return "Batch"
        case .cloud: return "Cloud"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "wand.and.stars"
        case .cutout: return "scissors"
        case .enhance: return "wand.and.rays"
        case .adjust: return "slider.horizontal.3"
        case .crop: return "crop"
        case .filters: return "camera.filters"
        case .overlays: return "textformat"
        case .erase: return "eraser"
        case .batch: return "square.stack"
        case .cloud: return "icloud"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}
