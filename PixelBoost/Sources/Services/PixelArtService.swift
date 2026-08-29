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

    /// 4x4 ordered (Bayer) dither matrix, values 0...15 — the standard
    /// pattern classic 16-bit-and-under hardware/software used to fake
    /// extra color resolution out of a small palette. Plain nearest-level
    /// rounding alone (no dithering) turns out to be nearly invisible for
    /// 5-6 bits/channel on an ordinary photo: 32-64 levels is still fine
    /// enough that flat quantization barely bands. The dither pattern is
    /// what actually reads as "reduced color depth" at a glance, which is
    /// the whole point of offering the toggle.
    private static let bayerMatrix: [[Double]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ]

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

        let rStep = channelStep(bits: channelBits.r)
        let gStep = channelStep(bits: channelBits.g)
        let bStep = channelStep(bits: channelBits.b)
        for y in 0..<height {
            // -0.5...0.5 of one quantization step — nudges this pixel's
            // rounding up or down depending on its position in the 4x4
            // tile, so two neighboring pixels that would otherwise both
            // round to the same flat level can instead land on adjacent
            // levels and alternate, which is what reads as a dither
            // texture rather than a flat color block.
            let rowDither = bayerMatrix[y % 4]
            for x in 0..<width {
                let dither = (rowDither[x % 4] + 0.5) / 16.0 - 0.5
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = quantizeChannel(pixels[offset], step: rStep, dither: dither)
                pixels[offset + 1] = quantizeChannel(pixels[offset + 1], step: gStep, dither: dither)
                pixels[offset + 2] = quantizeChannel(pixels[offset + 2], step: bStep, dither: dither)
            }
        }
        return ctx.makeImage()
    }

    private static func channelStep(bits: Int) -> Double {
        255.0 / Double((1 << bits) - 1)
    }

    /// Rounds `value` to the nearest representable level under `step`,
    /// offset by `dither` (a fraction of one step) before rounding — so the
    /// same input value can land on either of its two nearest levels
    /// depending on dither, instead of always the same one.
    private static func quantizeChannel(_ value: UInt8, step: Double, dither: Double) -> UInt8 {
        let level = (Double(value) / step + dither).rounded()
        let maxLevel = (255.0 / step).rounded()
        let clampedLevel = min(max(level, 0), maxLevel)
        return UInt8(min(255, max(0, (clampedLevel * step).rounded())))
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
