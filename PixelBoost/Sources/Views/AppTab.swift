import Foundation

/// Every top-level destination in the app. There are more than the ~5 iOS
/// puts in a native `TabView` before collapsing the rest into an
/// auto-generated "More" list, so `RootView` builds its own bar instead of
/// using `TabView`: 5 always-visible primary tabs (`primaryTabs`) plus a
/// center "Tools" button opening a drawer sheet for the rest (`moreTabs`).
enum AppTab: String, CaseIterable, Identifiable {
    case home, cutout, enhance, adjust, selective, crop, filters, overlays, erase, restore, clone, batch, cloud, history, settings

    var id: String { rawValue }

    /// The 5 tabs always visible in the bottom bar; everything else lives
    /// behind the center "Tools" button's drawer sheet (see `RootView`).
    /// Still just a `Bool` split of the same 15 cases, not a separate type —
    /// every tab keeps driving the same always-mounted `ZStack` in
    /// `RootView` regardless of which bucket it's in, so changing *how* a
    /// tab is reached never touches the state-preservation behavior that
    /// `ZStack` exists for.
    static let primaryTabs: [AppTab] = [.home, .adjust, .filters, .batch, .settings]
    static let moreTabs: [AppTab] = allCases.filter { !primaryTabs.contains($0) }

    var isPrimary: Bool { Self.primaryTabs.contains(self) }

    var title: String {
        switch self {
        case .home: return "Upscale"
        case .cutout: return "Cutout"
        case .enhance: return "Enhance"
        case .adjust: return "Adjust"
        case .selective: return "Selective"
        case .crop: return "Crop"
        case .filters: return "Filters"
        case .overlays: return "Overlays"
        case .erase: return "Erase"
        case .restore: return "Restore"
        case .clone: return "Clone"
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
        case .selective: return "paintbrush.pointed"
        case .crop: return "crop"
        case .filters: return "camera.filters"
        case .overlays: return "textformat"
        case .erase: return "eraser"
        case .restore: return "bandage"
        // Not "stamp" — that name doesn't resolve to a glyph on-device
        // (renders as a blank icon; confirmed via a real screenshot, not
        // just a lookup), even though it reads as valid in reference docs.
        // "doc.on.doc" is proven to render correctly in this exact app
        // already (ContentView's Copy action uses it) and reads reasonably
        // as "duplicate/clone" in an icon-only grid context.
        case .clone: return "doc.on.doc"
        case .batch: return "square.stack"
        case .cloud: return "icloud"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}
