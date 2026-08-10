import CoreGraphics
import CoreImage
import UIKit

/// Makes a texture tileable — the same "Offset + heal the seam" technique
/// Photoshop's Offset filter (wraparound mode) is built on, useful for
/// anyone exporting a texture map out of a render and needing it
/// game-ready. Two classical steps, no model:
/// 1. `wrapOffset` shifts the image by half its width/height with the
///    edges wrapping around — this moves the original (already-seamless
///    at its own edges, since the source image tiles trivially with
///    itself... except the ORIGINAL edges rarely actually match) border
///    into the middle of the canvas, where any mismatch is far more
///    forgiving to blend away than at the tile boundary itself.
/// 2. `healSeamCross` blends a blurred copy back in along a soft
///    cross-shaped band centered on the new (formerly-edge) seam lines,
///    smoothing the discontinuity without blurring the rest of the
///    texture.
enum SeamlessTextureService {
    private static let context = CIContext()

    /// Runs both steps — the actual "make seamless" entry point.
    /// - Parameter healWidth: width of the blended band around each seam
    ///   line, as a fraction of the image's shorter side (roughly 0.02...0.25).
    static func makeSeamless(_ image: UIImage, healWidth: Double = 0.08) -> UIImage {
        let wrapped = wrapOffset(image)
        return healSeamCross(wrapped, healWidth: healWidth)
    }

    /// Shifts the image by (width/2, height/2) with wraparound — draws the
    /// same image tiled at the four positions that, together, exactly
    /// cover the canvas once shifted. Equivalent to Photoshop's Offset
    /// filter with "Wrap Around" edge behavior.
    static func wrapOffset(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let size = image.size
        let halfW = size.width / 2
        let halfH = size.height / 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let img = UIImage(cgImage: cgImage)
            for dx in [halfW - size.width, halfW] {
                for dy in [halfH - size.height, halfH] {
                    img.draw(at: CGPoint(x: dx, y: dy))
                }
            }
        }
    }

    /// Blends a blurred copy of `image` back over itself, but only within
    /// a soft band straddling the vertical/horizontal center lines — the
    /// seams `wrapOffset` just introduced. Mask is generated directly with
    /// Core Graphics (two soft linear gradients, lightest right on the
    /// seam line, fading to fully transparent by `healWidth` away) rather
    /// than composed from multiple `CIFilter`s, since a hand-drawn mask is
    /// far easier to reason about pixel-for-pixel than stacking gradient/
    /// blend-mode filters to the same effect.
    static func healSeamCross(_ image: UIImage, healWidth: Double) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let size = image.size
        let shortSide = min(size.width, size.height)
        let band = max(4, shortSide * CGFloat(healWidth))

        let ciImage = CIImage(cgImage: cgImage)
        let blurred = ciImage
            .clampedToExtent()
            .applyingGaussianBlur(sigma: band / 3)
            .cropped(to: ciImage.extent)

        guard let mask = seamMask(size: size, band: band),
              let blurredCG = blurred.cgImage(using: context) else {
            return image
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(at: .zero)
            ctx.cgContext.saveGState()
            ctx.cgContext.clip(to: CGRect(origin: .zero, size: size), mask: mask)
            UIImage(cgImage: blurredCG).draw(at: .zero)
            ctx.cgContext.restoreGState()
        }
    }

    /// White (opaque) exactly on the center cross, fading to black
    /// (transparent, as a clip mask) by `band` pixels away — drawn as two
    /// overlapping axis-aligned gradients rather than derived from a blur,
    /// so the falloff width is exact and independent of the image's own
    /// content.
    private static func seamMask(size: CGSize, band: CGFloat) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))

        func drawBand(center: CGFloat, axis: NSLayoutConstraint.Axis) {
            let steps = 24
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let dist = t * band
                let intensity = max(0, 1 - t)
                ctx.setFillColor(gray: intensity, alpha: 1)
                switch axis {
                case .horizontal:
                    ctx.fill(CGRect(x: center - dist, y: 0, width: 2 * dist, height: size.height))
                default:
                    ctx.fill(CGRect(x: 0, y: center - dist, width: size.width, height: 2 * dist))
                }
            }
        }
        // Drawn back-to-front (largest/dimmest band first) so each
        // narrower, brighter step draws over it — same idea as painting
        // concentric rings from the outside in.
        drawBand(center: size.width / 2, axis: .horizontal)
        drawBand(center: size.height / 2, axis: .vertical)

        return ctx.makeImage()
    }
}

private extension CIImage {
    func cgImage(using context: CIContext) -> CGImage? {
        context.createCGImage(self, from: extent)
    }
}
