import SwiftUI
import UIKit

/// Every shape `FramesView` can mask a photo into. Backing raw values are
/// stored nowhere (not `Codable`, no persistence) — this only ever exists
/// as transient UI/render state for the current session, same as
/// `CropRotateView`'s `CropRatio`.
enum FrameShape: String, CaseIterable, Identifiable {
    case circle, square, roundedSquare, squircle, diamond, triangle, pentagon, hexagon, octagon, star, heart, cross

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return "Circle"
        case .square: return "Square"
        case .roundedSquare: return "Rounded"
        case .squircle: return "Squircle"
        case .diamond: return "Diamond"
        case .triangle: return "Triangle"
        case .pentagon: return "Pentagon"
        case .hexagon: return "Hexagon"
        case .octagon: return "Octagon"
        case .star: return "Star"
        case .heart: return "Heart"
        case .cross: return "Cross"
        }
    }
}

/// A `FrameShape`'s outline as a SwiftUI `Shape` — used both for the live
/// on-canvas preview (`.clipShape`) and, via `.path(in:).cgPath`, as the
/// exact clip region `FrameShapeService.apply` rasterizes with. Sharing one
/// geometry definition between preview and bake means what's on screen
/// before "Apply" is exactly what comes out after it, no separate math to
/// keep in sync.
struct FrameShapePath: Shape {
    let shape: FrameShape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            return Circle().path(in: rect)
        case .square:
            return Rectangle().path(in: rect)
        case .roundedSquare:
            return RoundedRectangle(cornerRadius: rect.width * 0.22, style: .continuous).path(in: rect)
        case .squircle:
            return RoundedRectangle(cornerRadius: rect.width * 0.45, style: .continuous).path(in: rect)
        case .diamond:
            return Self.regularPolygon(sides: 4, in: rect)
        case .triangle:
            return Self.regularPolygon(sides: 3, in: rect)
        case .pentagon:
            return Self.regularPolygon(sides: 5, in: rect)
        case .hexagon:
            return Self.regularPolygon(sides: 6, in: rect)
        case .octagon:
            return Self.regularPolygon(sides: 8, in: rect, rotationDegrees: 22.5)
        case .star:
            return Self.star(points: 5, in: rect)
        case .heart:
            return Self.heart(in: rect)
        case .cross:
            return Self.cross(in: rect)
        }
    }

    /// Vertices inscribed in the circle of radius `min(width, height) / 2`
    /// centered on `rect`, first vertex pointing straight up (baseline
    /// -90°) before `rotationDegrees` is applied — e.g. a 4-sided polygon
    /// at the default rotation lands points at top/right/bottom/left,
    /// i.e. a diamond, while `octagon` passes +22.5° (half a side's
    /// angular step) to land flats at top/bottom instead of points.
    private static func regularPolygon(sides: Int, in rect: CGRect, rotationDegrees: Double = 0) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let baseline = -90.0 + rotationDegrees
        var path = Path()
        for i in 0..<sides {
            let angle = Angle(degrees: baseline + Double(i) * (360.0 / Double(sides))).radians
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func star(points: Int, in rect: CGRect, innerRatio: CGFloat = 0.5) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * innerRatio
        var path = Path()
        let vertexCount = points * 2
        for i in 0..<vertexCount {
            let radius = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = Angle(degrees: -90.0 + Double(i) * (360.0 / Double(vertexCount))).radians
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Classic four-bezier-curve heart: two lobes meeting at a center dip,
    /// tapering to a point at the bottom.
    private static func heart(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY + h * 0.28)
        path.move(to: top)
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + h * 0.28),
            control1: CGPoint(x: rect.midX - w * 0.06, y: rect.minY + h * 0.06),
            control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.58),
            control2: CGPoint(x: rect.midX, y: rect.minY + h * 0.82)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.28),
            control1: CGPoint(x: rect.midX, y: rect.minY + h * 0.82),
            control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.58)
        )
        path.addCurve(
            to: top,
            control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.06),
            control2: CGPoint(x: rect.midX + w * 0.06, y: rect.minY + h * 0.06)
        )
        path.closeSubpath()
        return path
    }

    /// A plus/cross: 12 vertices around the center, `thicknessRatio` sets
    /// each arm's half-width as a fraction of the half-size.
    private static func cross(in rect: CGRect, thicknessRatio: CGFloat = 0.34) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * thicknessRatio
        let localPoints: [CGPoint] = [
            CGPoint(x: -inner, y: -outer), CGPoint(x: inner, y: -outer),
            CGPoint(x: inner, y: -inner), CGPoint(x: outer, y: -inner),
            CGPoint(x: outer, y: inner), CGPoint(x: inner, y: inner),
            CGPoint(x: inner, y: outer), CGPoint(x: -inner, y: outer),
            CGPoint(x: -inner, y: inner), CGPoint(x: -outer, y: inner),
            CGPoint(x: -outer, y: -inner), CGPoint(x: -inner, y: -inner),
        ]
        var path = Path()
        for (i, local) in localPoints.enumerated() {
            let point = CGPoint(x: center.x + local.x, y: center.y + local.y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Bakes a `FrameShape` onto a photo: crop to a square — by default
/// centered, or wherever `FramesView`'s pan/zoom gesture left it (see
/// `cropRect`) — then clip to the shape's path. Like every other renderer
/// chaining onto the shared result (see `ImageTransform`), `format.opaque
/// = false` is deliberate — everything outside the shape becomes
/// transparent, not flattened to black, and a prior Cutout's own
/// transparency is preserved rather than composited onto anything.
enum FrameShapeService {
    /// `cropRect` is in `image`'s own pixel space (top-left origin,
    /// y-down, same convention as `UIImage.cropped(to:)`) and may extend
    /// past `image`'s bounds — `cropped(to:)` already fills anything
    /// outside with transparency, so an over-zoomed/panned crop just
    /// shows a partial shape rather than crashing or clamping oddly.
    static func apply(_ shape: FrameShape, to image: UIImage, cropRect: CGRect) -> UIImage {
        let squared = image.cropped(to: cropRect)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: squared.size, format: format)
        return renderer.image { context in
            let clipPath = FrameShapePath(shape: shape).path(in: CGRect(origin: .zero, size: squared.size)).cgPath
            context.cgContext.addPath(clipPath)
            context.cgContext.clip()
            squared.draw(at: .zero)
        }
    }

    /// The default, centered square crop — `FramesView`'s starting
    /// position before any pan/zoom, and the fallback when the on-screen
    /// stage hasn't been measured yet.
    static func centeredCropRect(for imageSize: CGSize) -> CGRect {
        let side = min(imageSize.width, imageSize.height)
        return CGRect(x: (imageSize.width - side) / 2, y: (imageSize.height - side) / 2, width: side, height: side)
    }

    /// Converts `FramesView`'s on-screen pan/zoom state back into a pixel
    /// crop rect in `imageSize`'s own space. Mirrors exactly what's on
    /// screen: the preview shows `image` laid out with SwiftUI's own
    /// `.scaledToFill()` (scale = `stageSize / min(imageSize)`, the same
    /// formula it uses internally to fill a square frame) times the
    /// user's `zoomScale`, then shifted by `panOffset` — this inverts that
    /// same transform to find which square region of the source image is
    /// actually visible inside the stage.
    static func cropRect(imageSize: CGSize, stageSize: CGFloat, zoomScale: CGFloat, panOffset: CGSize) -> CGRect {
        guard stageSize > 0, imageSize.width > 0, imageSize.height > 0 else {
            return centeredCropRect(for: imageSize)
        }
        let baseScale = stageSize / min(imageSize.width, imageSize.height)
        let totalScale = baseScale * zoomScale
        let displayedSize = CGSize(width: imageSize.width * totalScale, height: imageSize.height * totalScale)

        // Top-left of the displayed (scaled) image, in stage coordinates —
        // centered, then shifted by the user's drag.
        let originX = (stageSize - displayedSize.width) / 2 + panOffset.width
        let originY = (stageSize - displayedSize.height) / 2 + panOffset.height

        // The stage square's own top-left is (0, 0) — the portion of the
        // displayed image it shows is the inverse of that origin, scaled
        // back down into the source image's own pixel space.
        return CGRect(
            x: -originX / totalScale, y: -originY / totalScale,
            width: stageSize / totalScale, height: stageSize / totalScale
        )
    }

    /// Clamps a candidate pan offset so the stage square never shows a gap
    /// past the (scaled) image's own edge — plain min/max, not fragile
    /// gesture math, same "keep it simple" reasoning `CropRotateView`
    /// gives for skipping free-angle straighten.
    static func clampedPanOffset(_ candidate: CGSize, imageSize: CGSize, stageSize: CGFloat, zoomScale: CGFloat) -> CGSize {
        guard stageSize > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let baseScale = stageSize / min(imageSize.width, imageSize.height)
        let totalScale = baseScale * zoomScale
        let displayedSize = CGSize(width: imageSize.width * totalScale, height: imageSize.height * totalScale)
        let maxX = max(0, (displayedSize.width - stageSize) / 2)
        let maxY = max(0, (displayedSize.height - stageSize) / 2)
        return CGSize(
            width: min(max(candidate.width, -maxX), maxX),
            height: min(max(candidate.height, -maxY), maxY)
        )
    }
}
