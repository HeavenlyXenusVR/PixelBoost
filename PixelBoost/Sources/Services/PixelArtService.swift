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
    /// Ignored when `Options.palette` is set to anything but `.none` — a
    /// fixed named palette already fully determines the output colors.
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

    /// Maps every pixel to whichever color in a small, fixed, real-hardware
    /// palette is nearest (plain Euclidean RGB distance) — a stronger,
    /// more authentic "retro" look than `colorLevels`' uniform posterize,
    /// since real 8-/16-bit era hardware didn't crush each channel
    /// independently, it picked from one curated, hand-tuned palette.
    /// Takes priority over `colorLevels`/`colorDepth` when set (both of
    /// those are just alternate ways of deriving a palette on the fly; a
    /// named palette already *is* one).
    enum RetroPalette: String, CaseIterable, Identifiable {
        case none = "None"
        case gameBoy = "Game Boy"
        case pico8 = "PICO-8"
        case nesish = "NES-ish"
        case cga = "CGA"
        case grayscale = "Grayscale"
        /// Not a fixed set — `colors` returns nil here too, same as
        /// `.none`. `apply()` special-cases this one to derive a palette
        /// from the photo itself (`Options.autoPaletteColorCount` colors,
        /// via `kMeansPalette`) instead of a named hardware palette, which
        /// is why it can't just return a fixed array like the others.
        case auto = "Auto from Photo"
        var id: String { rawValue }

        /// nil for `.none` — the "don't map to a fixed palette" case.
        var colors: [(r: UInt8, g: UInt8, b: UInt8)]? {
            switch self {
            case .none, .auto:
                return nil
            case .gameBoy:
                // The original DMG's four-shade green-gray LCD.
                return [(15, 56, 15), (48, 98, 48), (139, 172, 15), (155, 188, 15)]
            case .pico8:
                // The PICO-8 fantasy console's fixed 16-color palette.
                return [
                    (0, 0, 0), (29, 43, 83), (126, 37, 83), (0, 135, 81),
                    (171, 82, 54), (95, 87, 79), (194, 195, 199), (255, 241, 232),
                    (255, 0, 77), (255, 163, 0), (255, 236, 39), (0, 228, 54),
                    (41, 173, 255), (131, 118, 156), (255, 119, 168), (255, 204, 170),
                ]
            case .nesish:
                // A representative dozen from the NES's 54-color master
                // palette, not the whole thing — a full port would need a
                // proper YUV-space nearest match to look authentic; this
                // is a "reads as NES" approximation for a photo filter.
                return [
                    (0, 0, 0), (252, 252, 252), (188, 188, 188), (248, 56, 0),
                    (172, 124, 0), (0, 168, 0), (0, 136, 136), (0, 88, 248),
                    (136, 0, 236), (228, 0, 88), (88, 216, 84), (0, 232, 216),
                    (248, 120, 88), (252, 224, 168),
                ]
            case .cga:
                // CGA Palette 1, high intensity — the iconic
                // black/cyan/magenta/white 4-color mode.
                return [(0, 0, 0), (85, 255, 255), (255, 85, 255), (255, 255, 255)]
            case .grayscale:
                return stride(from: 0, through: 255, by: 255 / 7).map { (UInt8($0), UInt8($0), UInt8($0)) }
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
        /// Ignored when `palette` isn't `.none`.
        var colorLevels: Int?
        /// 16-bit (RGB565) or 32-bit (truecolor, the default — a no-op
        /// pass) per-pixel color depth, applied after posterizing. See
        /// `ColorDepth`. Ignored when `palette` isn't `.none`.
        var colorDepth: ColorDepth = .bit32
        /// Snaps every pixel to the nearest color in a named, fixed
        /// hardware palette instead of `colorLevels`/`colorDepth`'s
        /// independent-per-channel crush. See `RetroPalette`.
        var palette: RetroPalette = .none
        /// Only consulted when `palette == .auto` — how many colors
        /// `kMeansPalette` should extract from the photo's own colors.
        var autoPaletteColorCount: Int = 8
        /// A plain chroma-key fallback: treats whichever color is most
        /// common across the four corners of the pixelated result as
        /// "background" and makes every matching pixel transparent. Real
        /// subject-aware background removal (Vision's
        /// `VNGenerateForegroundInstanceMaskRequest`, same as the Cutout
        /// tool) happens *before* this at the call site — `PixelArtView`
        /// only sets this when Vision found no distinct subject to cut
        /// around, so Transparent Background still does something rather
        /// than nothing on a photo Vision can't segment (e.g. a flat
        /// texture with no foreground object).
        var transparentBackground: Bool = false
        /// When set, output is the small pixelated grid itself, sized so
        /// its longer side is exactly this many actual pixels — a real
        /// sprite-sheet-ready asset (e.g. 32x32), not `blockSize`'s
        /// preview-scale "blocky but still photo-resolution" result. `nil`
        /// (default) keeps the existing block-enlarged full-resolution
        /// output; `blockSize`/`showGrid` are ignored when this is set,
        /// since there's no enlarging step for either to apply to.
        var spriteSize: Int?
        /// 1.0 is unchanged; >1 punches up color intensity before
        /// pixelating (classic pixel-art palettes read as more vivid than
        /// an ordinary photo's colors), <1 mutes it. Applied before
        /// posterize/depth/palette so those steps quantize the boosted
        /// colors, not the original ones.
        var saturation: Double = 1.0
        /// Traces a black border around every block whose color differs
        /// enough from a right/bottom neighbor — the hard-edged outline
        /// classic pixel-art sprites use to separate shapes, rather than
        /// leaving adjacent same-ish-toned blocks to blur together.
        var outline: Bool = false
        /// Overlays faint 1px lines along every block boundary — makes the
        /// grid explicit rather than left to read off the color blocks
        /// alone.
        var showGrid: Bool = false
    }

    private static let context = CIContext()

    /// `.up` is already the overwhelming common case (every other tool's
    /// output, and most Photos-library assets on modern iOS) — cheap
    /// no-op check first, real work (and a `nil` on failure, rather than
    /// silently proceeding with unnormalized data) only for the rest.
    private static func normalizedOrientation(_ image: UIImage) -> UIImage? {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func apply(to image: UIImage, options: Options) -> UIImage? {
        // `cgImage.width/height` are the *raw* pixel buffer's dimensions —
        // they ignore `image.imageOrientation` entirely, unlike
        // `image.size`. For a non-`.up`-oriented UIImage (e.g. a 90°
        // sensor-orientation photo, common straight out of Photos) that
        // means width/height come out swapped relative to how the photo
        // actually displays, which would throw off every aspect-ratio
        // computation below (Export as Sprite's aspect-fit included).
        // Redrawing through a UIImage-level `.draw(in:)` (already
        // orientation-aware, see the fix note on `draw()` further down)
        // bakes the correct orientation into a fresh `.up`-oriented image
        // before any of this file's own math ever sees raw pixel counts.
        guard let normalizedImage = normalizedOrientation(image),
              let cgImage = normalizedImage.cgImage
        else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let blockSize = max(1, options.blockSize)

        let smallWidth: Int
        let smallHeight: Int
        if let spriteSize = options.spriteSize {
            // Fit to the longer side, same aspect-preserving math the
            // preview's own downscaling uses elsewhere in this app —
            // `blockSize` plays no role here, the grid *is* the sprite.
            let longSide = max(1, max(width, height))
            let scale = Double(max(1, spriteSize)) / Double(longSide)
            smallWidth = max(1, Int((Double(width) * scale).rounded()))
            smallHeight = max(1, Int((Double(height) * scale).rounded()))
        } else {
            smallWidth = max(1, width / blockSize)
            smallHeight = max(1, height / blockSize)
        }

        guard let shrunk = draw(
            cgImage, into: CGSize(width: smallWidth, height: smallHeight), interpolation: .default
        ) else { return nil }

        let saturated: CGImage
        if options.saturation != 1.0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = CIImage(cgImage: shrunk)
            filter.saturation = Float(max(0, options.saturation))
            guard let output = filter.outputImage,
                  let rendered = context.createCGImage(output, from: output.extent)
            else { return nil }
            saturated = rendered
        } else {
            saturated = shrunk
        }

        var colored: CGImage
        if options.palette == .auto {
            guard let buffer = readRGBA(saturated) else { return nil }
            let autoColors = kMeansPalette(buffer, k: max(2, min(32, options.autoPaletteColorCount)))
            colored = mapToPalette(saturated, colors: autoColors) ?? saturated
        } else if let paletteColors = options.palette.colors {
            colored = mapToPalette(saturated, colors: paletteColors) ?? saturated
        } else {
            let posterized: CGImage
            if let colorLevels = options.colorLevels {
                let filter = CIFilter.colorPosterize()
                filter.inputImage = CIImage(cgImage: saturated)
                filter.levels = Float(max(2, min(32, colorLevels)))
                guard let output = filter.outputImage,
                      let rendered = context.createCGImage(output, from: output.extent)
                else { return nil }
                posterized = rendered
            } else {
                posterized = saturated
            }

            if let bits = options.colorDepth.channelBits {
                colored = quantize(posterized, channelBits: bits) ?? posterized
            } else {
                colored = posterized
            }
        }

        if options.transparentBackground, let keyed = withTransparentBackground(colored) {
            colored = keyed
        }

        if options.spriteSize != nil {
            // Native pixel-per-pixel sprite output — no enlarge step, so
            // there's no "boundary between two pixels" to draw a separate
            // outline stroke along the way the block-enlarged path below
            // does; simply recoloring flagged edge pixels themselves is
            // the closest equivalent at this scale, at the cost of eating
            // one pixel into whichever side gets flagged rather than
            // drawing a clean line between the two.
            if options.outline, var buffer = readRGBA(colored) {
                paintEdgePixelsBlack(&buffer, mask: computeEdgeMask(buffer))
                colored = makeImage(buffer) ?? colored
            }
            return UIImage(cgImage: colored, scale: 1, orientation: .up)
        }

        // Snapped back to a whole number of blocks so the upscale step
        // below lands on exact block boundaries — avoids a partial,
        // slightly-off block at the right/bottom edge.
        let outputSize = CGSize(width: smallWidth * blockSize, height: smallHeight * blockSize)

        // Computed at the small (one-pixel-per-block) scale, same as
        // quantize/mapToPalette above, then drawn as thin lines at the
        // corresponding block boundaries in the full-size canvas below —
        // painting the small-grid pixels themselves black would blacken
        // whole blocks once nearest-neighbor-enlarged, not draw a border.
        let edgeMask = options.outline ? readRGBA(colored).map(computeEdgeMask) : nil

        guard let blocky = draw(colored, into: outputSize, interpolation: .none) else { return nil }

        let outlined: UIImage
        if let edgeMask {
            outlined = withOutline(blocky, mask: edgeMask, blockSize: blockSize, size: outputSize)
        } else {
            outlined = UIImage(cgImage: blocky, scale: 1, orientation: .up)
        }

        guard options.showGrid, let outlinedCG = outlined.cgImage else { return outlined }
        return withGrid(outlinedCG, blockSize: blockSize, size: outputSize)
    }

    /// One shared RGBA readback used by every per-pixel pass below
    /// (bit-depth quantize, palette mapping, edge detection) — all three
    /// need direct pixel access CoreImage/CIFilter can't give them, and
    /// all three run at the same small-grid scale, so it's the same
    /// buffer shape every time.
    private struct RGBABuffer {
        var pixels: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    private static func readRGBA(_ cgImage: CGImage) -> RGBABuffer? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // A manually-created CGContext defaults to Quartz's native
        // bottom-left-origin/y-up space, unlike UIGraphicsImageRenderer
        // (used by draw()/withGrid()/withOutline() below), which is
        // pre-flipped to match UIKit's top-left/y-down convention. Drawing
        // straight into this context without correcting for that stores
        // the image upside down relative to how its row-major bytes are
        // read back out below (row 0 assumed to be the visual top) — flip
        // the context first so the buffer this hands back actually reads
        // top-to-bottom.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBABuffer(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func makeImage(_ buffer: RGBABuffer) -> CGImage? {
        var pixels = buffer.pixels
        let ctx = CGContext(
            data: &pixels, width: buffer.width, height: buffer.height, bitsPerComponent: 8,
            bytesPerRow: buffer.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return ctx?.makeImage()
    }

    /// Snaps every pixel to the nearest color in `colors` by plain
    /// Euclidean RGB distance — good enough for a stylized photo filter;
    /// a perceptual (e.g. Lab-space) distance would matter more for exact
    /// hardware-accurate palette reduction than this needs.
    private static func mapToPalette(_ cgImage: CGImage, colors: [(r: UInt8, g: UInt8, b: UInt8)]) -> CGImage? {
        guard var buffer = readRGBA(cgImage) else { return nil }
        var offset = 0
        while offset < buffer.pixels.count {
            let r = Int(buffer.pixels[offset])
            let g = Int(buffer.pixels[offset + 1])
            let b = Int(buffer.pixels[offset + 2])
            var bestIndex = 0
            var bestDistance = Int.max
            for (index, color) in colors.enumerated() {
                let dr = r - Int(color.r), dg = g - Int(color.g), db = b - Int(color.b)
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            let match = colors[bestIndex]
            buffer.pixels[offset] = match.r
            buffer.pixels[offset + 1] = match.g
            buffer.pixels[offset + 2] = match.b
            offset += 4
        }
        return makeImage(buffer)
    }

    /// Derives a `k`-color palette from `buffer`'s own pixels via a plain
    /// Lloyd's-algorithm k-means over RGB space — run on the already-small
    /// (one-pixel-per-block) grid, so even a fixed handful of iterations
    /// over every pixel stays cheap. Centroids seed from `k` evenly-spaced
    /// pixels across the image (not random) so the result is deterministic
    /// for the same input — matters here since this feeds a live preview
    /// that re-runs on every slider tweak, and a flickering-between-runs
    /// palette would read as a bug.
    private static func kMeansPalette(_ buffer: RGBABuffer, k: Int, iterations: Int = 6) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let totalPixels = buffer.width * buffer.height
        guard totalPixels > 0, k > 0 else { return [(128, 128, 128)] }
        let step = max(1, totalPixels / k)
        var centroids: [(r: Double, g: Double, b: Double)] = (0..<k).map { i in
            let pixelIndex = min(i * step, totalPixels - 1)
            let offset = pixelIndex * 4
            return (Double(buffer.pixels[offset]), Double(buffer.pixels[offset + 1]), Double(buffer.pixels[offset + 2]))
        }

        for _ in 0..<iterations {
            var sums = [(r: Double, g: Double, b: Double, count: Int)](repeating: (0, 0, 0, 0), count: centroids.count)
            var offset = 0
            while offset < buffer.pixels.count {
                let r = Double(buffer.pixels[offset]), g = Double(buffer.pixels[offset + 1]), b = Double(buffer.pixels[offset + 2])
                var bestIndex = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (index, centroid) in centroids.enumerated() {
                    let dr = r - centroid.r, dg = g - centroid.g, db = b - centroid.b
                    let distance = dr * dr + dg * dg + db * db
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
                sums[bestIndex].r += r
                sums[bestIndex].g += g
                sums[bestIndex].b += b
                sums[bestIndex].count += 1
                offset += 4
            }
            for index in centroids.indices where sums[index].count > 0 {
                let count = Double(sums[index].count)
                centroids[index] = (sums[index].r / count, sums[index].g / count, sums[index].b / count)
            }
        }

        return centroids.map { centroid in
            (
                UInt8(min(255, max(0, centroid.r.rounded()))),
                UInt8(min(255, max(0, centroid.g.rounded()))),
                UInt8(min(255, max(0, centroid.b.rounded())))
            )
        }
    }

    /// Packs a pixel's RGB into one comparable key.
    private static func colorKey(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        Int(r) << 16 | Int(g) << 8 | Int(b)
    }

    /// Finds whichever color is most common across the four corners of
    /// `cgImage` and makes every pixel within a fixed distance of it fully
    /// transparent — a plain chroma-key, not a proper subject segmentation
    /// (see `BackgroundRemovalService`/Cutout for that); works well enough
    /// for the common case this targets, a sprite photographed or rendered
    /// against one flat backdrop color.
    private static func withTransparentBackground(_ cgImage: CGImage) -> CGImage? {
        guard var buffer = readRGBA(cgImage), buffer.width > 0, buffer.height > 0 else { return nil }
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = y * buffer.bytesPerRow + x * 4
            return (buffer.pixels[offset], buffer.pixels[offset + 1], buffer.pixels[offset + 2])
        }
        let corners = [
            pixel(0, 0), pixel(buffer.width - 1, 0),
            pixel(0, buffer.height - 1), pixel(buffer.width - 1, buffer.height - 1),
        ]
        var counts: [Int: Int] = [:]
        for corner in corners {
            counts[colorKey(corner.0, corner.1, corner.2), default: 0] += 1
        }
        guard let backgroundKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bgR = (backgroundKey >> 16) & 0xFF, bgG = (backgroundKey >> 8) & 0xFF, bgB = backgroundKey & 0xFF

        let threshold = 40
        var offset = 0
        while offset < buffer.pixels.count {
            let dr = Int(buffer.pixels[offset]) - bgR
            let dg = Int(buffer.pixels[offset + 1]) - bgG
            let db = Int(buffer.pixels[offset + 2]) - bgB
            if abs(dr) + abs(dg) + abs(db) <= threshold {
                // Zeroing RGB alongside alpha keeps this a valid
                // premultiplied pixel (premultiplied color can never
                // exceed its own alpha) — leaving stale color behind a
                // zero alpha is harmless in most viewers but not spec-
                // correct, and costs nothing extra to avoid here.
                buffer.pixels[offset] = 0
                buffer.pixels[offset + 1] = 0
                buffer.pixels[offset + 2] = 0
                buffer.pixels[offset + 3] = 0
            }
            offset += 4
        }
        return makeImage(buffer)
    }

    /// Recolors every pixel `mask` flags as a right/bottom edge to black,
    /// in place — the native-sprite-scale equivalent of `withOutline`
    /// below, which instead draws a separate line at block boundaries in
    /// an already-enlarged canvas; at 1-pixel-per-block scale there's no
    /// such boundary to draw a line along; see `Options.spriteSize`.
    private static func paintEdgePixelsBlack(_ buffer: inout RGBABuffer, mask: EdgeMask) {
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let index = y * mask.width + x
                guard mask.rightEdges[index] || mask.bottomEdges[index] else { continue }
                let offset = y * buffer.bytesPerRow + x * 4
                buffer.pixels[offset] = 0
                buffer.pixels[offset + 1] = 0
                buffer.pixels[offset + 2] = 0
            }
        }
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
        guard var buffer = readRGBA(cgImage) else { return nil }
        let rStep = channelStep(bits: channelBits.r)
        let gStep = channelStep(bits: channelBits.g)
        let bStep = channelStep(bits: channelBits.b)
        for y in 0..<buffer.height {
            // -0.5...0.5 of one quantization step — nudges this pixel's
            // rounding up or down depending on its position in the 4x4
            // tile, so two neighboring pixels that would otherwise both
            // round to the same flat level can instead land on adjacent
            // levels and alternate, which is what reads as a dither
            // texture rather than a flat color block.
            let rowDither = bayerMatrix[y % 4]
            for x in 0..<buffer.width {
                let dither = (rowDither[x % 4] + 0.5) / 16.0 - 0.5
                let offset = y * buffer.bytesPerRow + x * 4
                buffer.pixels[offset] = quantizeChannel(buffer.pixels[offset], step: rStep, dither: dither)
                buffer.pixels[offset + 1] = quantizeChannel(buffer.pixels[offset + 1], step: gStep, dither: dither)
                buffer.pixels[offset + 2] = quantizeChannel(buffer.pixels[offset + 2], step: bStep, dither: dither)
            }
        }
        return makeImage(buffer)
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

    /// Which block boundaries differ enough (summed absolute channel
    /// difference past a fixed threshold) between neighbors to warrant an
    /// outline stroke — only right/bottom neighbors are checked since a
    /// boundary belongs equally to both blocks either side of it; checking
    /// left/top too would just find and draw the same boundary twice.
    private struct EdgeMask {
        var rightEdges: [Bool]
        var bottomEdges: [Bool]
        let width: Int
        let height: Int
    }

    /// Computed at the small (one-pixel-per-block) scale, same as
    /// `quantize`/`mapToPalette` — `width`/`height` here are block counts,
    /// not output pixels.
    private static func computeEdgeMask(_ buffer: RGBABuffer) -> EdgeMask {
        let threshold = 60
        var rightEdges = [Bool](repeating: false, count: buffer.width * buffer.height)
        var bottomEdges = rightEdges
        func diff(_ o1: Int, _ o2: Int) -> Int {
            abs(Int(buffer.pixels[o1]) - Int(buffer.pixels[o2]))
                + abs(Int(buffer.pixels[o1 + 1]) - Int(buffer.pixels[o2 + 1]))
                + abs(Int(buffer.pixels[o1 + 2]) - Int(buffer.pixels[o2 + 2]))
        }
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let offset = y * buffer.bytesPerRow + x * 4
                let index = y * buffer.width + x
                if x + 1 < buffer.width, diff(offset, offset + 4) > threshold {
                    rightEdges[index] = true
                }
                if y + 1 < buffer.height, diff(offset, offset + buffer.bytesPerRow) > threshold {
                    bottomEdges[index] = true
                }
            }
        }
        return EdgeMask(rightEdges: rightEdges, bottomEdges: bottomEdges, width: buffer.width, height: buffer.height)
    }

    /// Strokes a thin black line along every flagged block boundary in
    /// `mask`, drawn directly on the already block-enlarged `cgImage` (one
    /// batched path covering every boundary, rather than one `stroke()`
    /// call per block — the block count can run into the hundreds of
    /// thousands on a small `blockSize`/large photo, and CGContext's
    /// per-call overhead adds up fast at that scale).
    private static func withOutline(_ cgImage: CGImage, mask: EdgeMask, blockSize: Int, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = UIImage(cgImage: cgImage)
        return renderer.image { rendererContext in
            // UIImage-level draw, not the raw CGContext.draw(cgImage:in:)
            // this used to call — the latter draws a CGImage's bytes
            // straight through without correcting for
            // UIGraphicsImageRenderer's flipped (UIKit-style) coordinate
            // space, so the result came out upside down. Every other
            // drawing helper in this app (Watermark, FiltersView,
            // AdjustmentsView, ...) already draws via UIImage for exactly
            // this reason — this file was the one inconsistent holdout.
            image.draw(in: CGRect(origin: .zero, size: size))
            let path = CGMutablePath()
            for y in 0..<mask.height {
                for x in 0..<mask.width {
                    let index = y * mask.width + x
                    if mask.rightEdges[index] {
                        let lineX = CGFloat((x + 1) * blockSize)
                        path.move(to: CGPoint(x: lineX, y: CGFloat(y * blockSize)))
                        path.addLine(to: CGPoint(x: lineX, y: CGFloat((y + 1) * blockSize)))
                    }
                    if mask.bottomEdges[index] {
                        let lineY = CGFloat((y + 1) * blockSize)
                        path.move(to: CGPoint(x: CGFloat(x * blockSize), y: lineY))
                        path.addLine(to: CGPoint(x: CGFloat((x + 1) * blockSize), y: lineY))
                    }
                }
            }
            let strokeContext = rendererContext.cgContext
            strokeContext.addPath(path)
            strokeContext.setStrokeColor(UIColor.black.cgColor)
            strokeContext.setLineWidth(max(1, CGFloat(blockSize) * 0.15))
            strokeContext.strokePath()
        }
    }

    private static func draw(_ cgImage: CGImage, into size: CGSize, interpolation: CGInterpolationQuality) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let sourceImage = UIImage(cgImage: cgImage)
        let image = renderer.image { rendererContext in
            rendererContext.cgContext.interpolationQuality = interpolation
            // See withOutline's comment — UIImage-level draw, not raw
            // CGContext.draw(cgImage:in:), so this doesn't come out
            // upside down inside UIGraphicsImageRenderer's flipped context.
            sourceImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    private static func withGrid(_ cgImage: CGImage, blockSize: Int, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = UIImage(cgImage: cgImage)
        return renderer.image { rendererContext in
            image.draw(in: CGRect(origin: .zero, size: size))
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
