import Foundation

/// Every top-level destination in the app. There are far more than the ~5
/// a native `TabView` shows, so `RootView` builds its own floating dock:
/// five fixed destinations (`primaryTabs`), with every editing tool reached
/// through the `.tools` library screen.
enum AppTab: String, CaseIterable, Identifiable {
    case home, tools, cutout, enhance, adjust, selective, crop, frames, filters, pixelArt, scripted, overlays, erase, restore, renderDenoise, normalMap, seamlessTexture, depthFog, aoBlend, lut, clone, batch, cloud, history, settings

    var id: String { rawValue }

    /// The dock, left to right.
    static let primaryTabs: [AppTab] = [.home, .tools, .batch, .history, .settings]

    var isPrimary: Bool { Self.primaryTabs.contains(self) }

    /// A screen reached from the Tools library (lights up the Tools slot
    /// in the dock while it's open).
    var isTool: Bool { !isPrimary }

    /// How the Tools library groups its tiles.
    enum Category: String, CaseIterable, Identifiable {
        case fix = "Fix & Enhance"
        case adjust = "Tone & Color"
        case create = "Create"
        case texture = "3D & Textures"
        case library = "Library"

        var id: String { rawValue }

        var tabs: [AppTab] {
            switch self {
            case .fix: return [.enhance, .restore, .renderDenoise, .cutout, .erase, .clone]
            case .adjust: return [.adjust, .selective, .crop, .filters, .lut]
            case .create: return [.frames, .overlays, .pixelArt, .scripted]
            case .texture: return [.normalMap, .seamlessTexture, .depthFog, .aoBlend]
            case .library: return [.cloud]
            }
        }
    }

    /// One line for the Tools library tile.
    var blurb: String {
        switch self {
        case .home: return "Full-resolution AI upscaling"
        case .tools: return "Every editing tool"
        case .cutout: return "Lift the subject, swap the background"
        case .enhance: return "One-tap exposure and color"
        case .adjust: return "Light, color and tone curve"
        case .selective: return "Paint where an adjustment applies"
        case .crop: return "Rotate and crop to a ratio"
        case .frames: return "Borders and shaped frames"
        case .filters: return "Film-style looks"
        case .pixelArt: return "Retro palettes, crisp blocks"
        case .scripted: return "Per-pixel Lua scripts"
        case .overlays: return "Text and emoji on top"
        case .erase: return "Paint out distractions"
        case .restore: return "Denoise and sharpen faces"
        case .renderDenoise: return "Clean noisy 3D renders"
        case .normalMap: return "Generate a normal map"
        case .seamlessTexture: return "Make a tileable texture"
        case .depthFog: return "Atmospheric depth haze"
        case .aoBlend: return "Ambient-occlusion shading"
        case .lut: return "Apply a .cube color LUT"
        case .clone: return "Copy pixels from a source"
        case .batch: return "Queue many photos"
        case .cloud: return "Temporary cloud copies"
        case .history: return "Past upscales and stats"
        case .settings: return "Defaults, export, power"
        }
    }

    var title: String {
        switch self {
        case .home: return "Upscale"
        case .tools: return "Tools"
        case .cutout: return "Cutout"
        case .enhance: return "Enhance"
        case .adjust: return "Adjust"
        case .selective: return "Selective"
        case .crop: return "Crop"
        case .frames: return "Frames"
        case .filters: return "Filters"
        case .pixelArt: return "Pixel Art"
        case .scripted: return "Scripted"
        case .overlays: return "Overlays"
        case .erase: return "Erase"
        case .restore: return "Restore"
        case .renderDenoise: return "Render Denoise"
        case .normalMap: return "Normal Map"
        case .seamlessTexture: return "Seamless Texture"
        case .depthFog: return "Depth Fog"
        case .aoBlend: return "AO Blend"
        case .lut: return "LUT"
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
        case .tools: return "square.grid.2x2"
        case .cutout: return "scissors"
        case .enhance: return "wand.and.rays"
        case .adjust: return "slider.horizontal.3"
        case .selective: return "paintbrush.pointed"
        case .crop: return "crop"
        case .frames: return "square.on.circle"
        case .filters: return "camera.filters"
        case .pixelArt: return "square.grid.3x3.fill"
        // Documented as an SF Symbol since iOS 13, but like every other
        // icon choice in this app, not checked against a real device — see
        // the `.clone` case above for why that check matters.
        case .scripted: return "chevron.left.slash.chevron.right"
        case .overlays: return "textformat"
        case .erase: return "eraser"
        case .restore: return "bandage"
        case .renderDenoise: return "cube"
        case .normalMap: return "arrow.up.arrow.down.square"
        case .seamlessTexture: return "square.grid.3x3"
        case .depthFog: return "cloud.fog"
        case .aoBlend: return "cube"
        case .lut: return "square.stack.3d.up"
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
