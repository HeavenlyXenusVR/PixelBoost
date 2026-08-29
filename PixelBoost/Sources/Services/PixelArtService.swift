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
    /// Per-channel bit depth applied after posterizing (if any) — a
    /// separate knob from `colorLevels`'s flat "N steps on every channel"
    /// crush: this reproduces the actual RGB565/RGBA8888 bit layouts real
    /// 16-bit- and 32-bit-era console/handheld hardware rendered with, so
    /// picking "16-bit" gives back that hardware's real color-banding
    /// character (5 bits red, 6 green, 5 blue — green gets the extra bit
    /// because the eye is most sensitive to it, same reasoning the actual
    /// RGB565 format used) rather than an arbitrary uniform posterize.
    enum ColorDepth: String, CaseIterable, Identifiable {
        case bit16 = "16-bit"
        case bit32 = "32-bit"
        var id: String { rawValue }

        /// (red, green, blue) bits — alpha is always left untouched.
        var channelBits: (r: Int, g: Int, b: Int)? {
            switch self {
            case .bit16: return (5, 6, 5)
            case .bit32: return nil // full 8-bit-per-channel truecolor — no quantization needed
            }
        }
    }

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
        /// 16-bit (RGB565) or 32-bit (truecolor, the default — a no-op
        /// pass) per-pixel color depth, applied after posterizing. See
        /// `ColorDepth`.
        var colorDepth: ColorDepth = .bit32
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

        let depthQuantized: CGImage
        if let bits = options.colorDepth.channelBits {
            depthQuantized = quantize(posterized, channelBits: bits) ?? posterized
        } else {
            depthQuantized = posterized
        }

        guard let blocky = draw(depthQuantized, into: outputSize, interpolation: .none) else { return nil }

        guard options.showGrid else { return UIImage(cgImage: blocky, scale: 1, orientation: .up) }
        return withGrid(blocky, blockSize: blockSize, size: outputSize)
    }

    /// Quantizes each channel down to `channelBits.r/g/b` levels, run on
    /// the already-shrunk (small-grid) image rather than the full-size
    /// photo — cheap enough for a plain per-pixel loop since it's at most
    /// a few hundred thousand pixels by this point, not the original
    /// multi-megapixel source.
    private static func quantize(_ cgImage: CGImage, channelBits: (r: Int, g: Int, b: Int)) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return cgImage }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let rTable = quantizationTable(bits: channelBits.r)
        let gTable = quantizationTable(bits: channelBits.g)
        let bTable = quantizationTable(bits: channelBits.b)
        var i = 0
        while i < pixels.count {
            pixels[i] = rTable[Int(pixels[i])]
            pixels[i + 1] = gTable[Int(pixels[i + 1])]
            pixels[i + 2] = bTable[Int(pixels[i + 2])]
            i += 4
        }
        return ctx.makeImage()
    }

    /// Maps every 0...255 input value to the nearest representable value
    /// under `bits`-per-channel precision — e.g. 5 bits -> 32 evenly-spaced
    /// output levels across the full 0...255 range, rather than just
    /// truncating the low bits (which would darken highlights toward the
    /// nearest level *below* them instead of the nearest level overall).
    private static func quantizationTable(bits: Int) -> [UInt8] {
        let levels = 1 << bits
        let step = 255.0 / Double(levels - 1)
        return (0...255).map { value in
            let level = (Double(value) / step).rounded()
            return UInt8(min(255, max(0, (level * step).rounded())))
        }
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
