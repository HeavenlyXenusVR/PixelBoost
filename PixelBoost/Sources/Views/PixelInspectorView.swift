import SwiftUI

/// Pixel-level before/after inspection. Drag the crosshair over the photo;
/// the two loupes show the *real* full-resolution pixels under it — the
/// original's and the result's, covering the same patch of the scene — at
/// nearest-neighbor magnification with a pixel grid, plus the exact color
/// of the center pixel. It's how you check what the model actually did,
/// pixel by pixel, rather than trusting a screen-sized preview.
///
/// Cheap: each loupe is a `CGImage.cropping(to:)` of a few dozen pixels
/// (no copy of the full image), redone only when the crosshair moves.
struct PixelInspectorView: View {
    let before: UIImage?
    let after: UIImage
    /// Screen-sized copy used for the navigator.
    let display: UIImage
    @Environment(\.dismiss) private var dismiss

    @State private var point = CGPoint(x: 0.5, y: 0.5)
    @State private var span: Int = 24

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                navigator
                PBSegmented(options: [12, 24, 48], selection: $span, label: { "\($0) px" })
                    .padding(.horizontal, PBLayout.gutter)
                HStack(spacing: 10) {
                    if let before {
                        loupe(title: "Before", image: before)
                    }
                    loupe(title: "After", image: after)
                }
                .padding(.horizontal, PBLayout.gutter)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Pixel Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var navigator: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Image(uiImage: display)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                let side = max(10, size.width * CGFloat(span) / CGFloat(max(1, after.cgImage?.width ?? 1)))
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .background(Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 3))
                    .frame(width: side, height: side)
                    .position(x: point.x * size.width, y: point.y * size.height)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    point = CGPoint(
                        x: min(1, max(0, value.location.x / max(1, size.width))),
                        y: min(1, max(0, value.location.y / max(1, size.height)))
                    )
                }
            )
        }
        .aspectRatio(display.size.width / max(1, display.size.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PBColor.lineStrong, lineWidth: 1))
        .padding(.horizontal, PBLayout.gutter)
        .frame(maxHeight: 340)
    }

    /// The same patch of the scene in either image: `span` result pixels
    /// wide, and proportionally fewer original pixels.
    private func region(in image: CGImage) -> CGRect {
        let resultWidth = Double(after.cgImage?.width ?? image.width)
        let side = max(2, Int((Double(span) * Double(image.width) / resultWidth).rounded()))
        let cx = Int(point.x * Double(image.width))
        let cy = Int(point.y * Double(image.height))
        let x = min(max(0, cx - side / 2), max(0, image.width - side))
        let y = min(max(0, cy - side / 2), max(0, image.height - side))
        return CGRect(x: x, y: y, width: min(side, image.width), height: min(side, image.height))
    }

    private func loupe(title: String, image: UIImage) -> some View {
        let cg = image.cgImage
        let rect = cg.map(region(in:)) ?? .zero
        let crop = cg?.cropping(to: rect)
        let center = cg.flatMap { Self.color(in: $0, at: CGPoint(x: rect.midX, y: rect.midY)) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).pbFont(.eyebrow).foregroundStyle(PBColor.inkFaint)
                Spacer()
                Text("\(Int(rect.width))px").pbFont(.monoSmall).foregroundStyle(PBColor.inkDim)
            }
            ZStack {
                if let crop {
                    Image(decorative: crop, scale: 1)
                        .resizable()
                        .interpolation(.none)
                }
                if Int(rect.width) <= 48 {
                    Canvas { context, size in
                        let n = max(1, Int(rect.width))
                        var grid = Path()
                        for i in 1..<n {
                            let p = size.width * CGFloat(i) / CGFloat(n)
                            grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: size.width, y: p))
                        }
                        context.stroke(grid, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(PBCheckerboard())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PBColor.lineStrong, lineWidth: 1))
            if let center {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(red: center.r, green: center.g, blue: center.b)).frame(width: 12, height: 12)
                    Text(center.hex).pbFont(.monoSmall).foregroundStyle(PBColor.ink)
                    Spacer()
                    if let cg {
                        Text("\(Int(rect.midX)),\(Int(rect.midY)) / \(cg.width)×\(cg.height)")
                            .pbFont(.monoSmall).foregroundStyle(PBColor.inkFaint)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private struct PixelColor {
        let r: Double, g: Double, b: Double
        var hex: String {
            String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }

    /// Reads one pixel by drawing a 1×1 crop into a 4-byte buffer.
    private static func color(in image: CGImage, at point: CGPoint) -> PixelColor? {
        let x = min(max(0, Int(point.x)), image.width - 1)
        let y = min(max(0, Int(point.y)), image.height - 1)
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return PixelColor(r: Double(bytes[0]) / 255, g: Double(bytes[1]) / 255, b: Double(bytes[2]) / 255)
    }
}
