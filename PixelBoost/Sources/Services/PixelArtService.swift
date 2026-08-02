import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Converts a photo into a retro "pixel art" look — the same three-step
/// recipe most pixelation tools use: shrink to a small grid (so detail
/// collapses into flat blocks), optionally crush the palette down to a
/// handful of posterized color steps, then blow it back up with
/// nearest-neighbor scaling so every block reads as one hard-edged square
/// instead of a blurry downscale.
enum PixelArtService {
    struct Options {
        /// Size (in *output* pixels) of one "pixel" block — how chunky the
        /// result looks. 4...40 is a sane range; the block count is derived
        /// from this and the source image's own size, not a fixed grid, so
        /// portrait/landscape photos both keep square blocks.
        var blockSize: Int = 10
        /// Posterization levels per color channel via `CIColorPosterize`
        /// (2...32) — lower reads as a more limited retro palette. `nil`
        /// skips posterizing entirely (blocky shapes, full color range).
        var colorLevels: Int?
        /// Overlays faint 1px lines along every block boundary — makes the
        /// grid explicit rather than left to read off the color blocks
        /// alone.
        var showGrid: Bool = false
    }

    private static let context = CIContext()

    static func apply(to image: UIImage, options: Options) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let blockSize = max(1, options.blockSize)
        let smallWidth = max(1, width / blockSize)
        let smallHeight = max(1, height / blockSize)
        // Snapped back to a whole number of blocks so the upscale step below
        // lands on exact block boundaries — avoids a partial, slightly-off
        // block at the right/bottom edge.
        let outputSize = CGSize(width: smallWidth * blockSize, height: smallHeight * blockSize)

        guard let shrunk = draw(
            cgImage, into: CGSize(width: smallWidth, height: smallHeight), interpolation: .default
        ) else { return nil }

        let posterized: CGImage
        if let colorLevels = options.colorLevels {
            let filter = CIFilter.colorPosterize()
            filter.inputImage = CIImage(cgImage: shrunk)
            filter.levels = Float(max(2, min(32, colorLevels)))
            guard let output = filter.outputImage,
                  let rendered = context.createCGImage(output, from: output.extent)
            else { return nil }
            posterized = rendered
        } else {
            posterized = shrunk
        }

        guard let blocky = draw(posterized, into: outputSize, interpolation: .none) else { return nil }

        guard options.showGrid else { return UIImage(cgImage: blocky, scale: 1, orientation: .up) }
        return withGrid(blocky, blockSize: blockSize, size: outputSize)
    }

    private static func draw(_ cgImage: CGImage, into size: CGSize, interpolation: CGInterpolationQuality) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            rendererContext.cgContext.interpolationQuality = interpolation
            rendererContext.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    private static func withGrid(_ cgImage: CGImage, blockSize: Int, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            rendererContext.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
            let gridContext = rendererContext.cgContext
            gridContext.setStrokeColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            gridContext.setLineWidth(1)
            var x = 0
            while x <= Int(size.width) {
                gridContext.move(to: CGPoint(x: CGFloat(x), y: 0))
                gridContext.addLine(to: CGPoint(x: CGFloat(x), y: size.height))
                x += blockSize
            }
            var y = 0
            while y <= Int(size.height) {
                gridContext.move(to: CGPoint(x: 0, y: CGFloat(y)))
                gridContext.addLine(to: CGPoint(x: size.width, y: CGFloat(y)))
                y += blockSize
            }
            gridContext.strokePath()
        }
    }
}
