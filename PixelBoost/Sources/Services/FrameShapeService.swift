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

/// Bakes a `FrameShape` onto a photo: center-crop to a square (the shapes
/// above all assume one), then clip to the shape's path. Like every other
/// renderer chaining onto the shared result (see `ImageTransform`),
/// `format.opaque = false` is deliberate — everything outside the shape
/// becomes transparent, not flattened to black, and a prior Cutout's own
/// transparency is preserved rather than composited onto anything.
enum FrameShapeService {
    static func apply(_ shape: FrameShape, to image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let squareRect = CGRect(
            x: (image.size.width - side) / 2, y: (image.size.height - side) / 2,
            width: side, height: side
        )
        let squared = image.cropped(to: squareRect)

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
}
