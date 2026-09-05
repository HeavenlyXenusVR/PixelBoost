import CoreGraphics
import UIKit

/// Wraps any `ImageUpscaling` and resizes its output to a different final
/// scale than the base strategy's native one — e.g. a Core ML model that's
/// architecturally fixed at 4x can still deliver a 2x or 3x *final* image
/// this way. Downsampling a sharper 4x result is a better source of detail
/// for a smaller target than any model trained to output that ratio
/// directly would be for the tile sizes this app uses, so this is a
/// deliberate design choice, not a shortcut around real 2x/3x models.
///
/// `techniqueInfo`/logging still reports the *base* strategy's native scale
/// factor (e.g. 4), not the final requested one — it describes how the
/// model itself was invoked. The actual delivered size is always accurate
/// via the result image's own dimensions (`UpscaleRunner` logs
/// `output_width`/`output_height` straight from `result.image.size`), so
/// the two figures stay individually correct even though they can differ.
struct ScaledOutputUpscaler: ImageUpscaling {
    let base: ImageUpscaling
    let nativeScale: Int
    let targetScale: Int

    var techniqueInfo: UpscaleTechniqueInfo { base.techniqueInfo }

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        let result = try await base.upscale(image, progress: progress)
        guard targetScale != nativeScale else { return result }

        let targetSize = CGSize(
            width: (image.size.width * CGFloat(targetScale)).rounded(),
            height: (image.size.height * CGFloat(targetScale)).rounded()
        )
        let resized = Self.resize(result.image, to: targetSize)
        return UpscaleResult(image: resized, tileCount: result.tileCount)
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard let cgImage = image.cgImage,
              size.width > 0, size.height > 0,
              let sourceImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up).cgImage
        else { return image }

        let srcWidth = sourceImage.width
        let srcHeight = sourceImage.height
        let dstWidth = Int(size.width.rounded())
        let dstHeight = Int(size.height.rounded())
        let bytesPerPixel = 4
        let srcBytesPerRow = srcWidth * bytesPerPixel
        let dstBytesPerRow = dstWidth * bytesPerPixel
        let srcByteCount = srcWidth * srcHeight * bytesPerPixel
        let dstByteCount = dstWidth * dstHeight * bytesPerPixel

        var srcPixels = [UInt8](repeating: 0, count: srcByteCount)
        let srcCtx = CGContext(
            data: &srcPixels,
            width: srcWidth,
            height: srcHeight,
            bitsPerComponent: 8,
            bytesPerRow: srcBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        UIGraphicsPushContext(srcCtx)
        UIImage(cgImage: sourceImage).draw(in: CGRect(x: 0, y: 0, width: srcWidth, height: srcHeight))
        UIGraphicsPopContext()

        var dstPixels = [UInt8](repeating: 0, count: dstByteCount)
        let dstCtx = CGContext(
            data: &dstPixels,
            width: dstWidth,
            height: dstHeight,
            bitsPerComponent: 8,
            bytesPerRow: dstBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        func rgba(_ buffer: [UInt8], x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let idx = (y * srcWidth + x) * bytesPerPixel
            return (
                Double(buffer[idx]),
                Double(buffer[idx + 1]),
                Double(buffer[idx + 2]),
                Double(buffer[idx + 3])
            )
        }

        func clampChannel(_ value: Double) -> UInt8 {
            UInt8(max(0, min(255, value.rounded())))
        }

        func sampleBilinear(_ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double, a: Double) {
            let x0 = max(0, min(srcWidth - 1, floor(x)))
            let y0 = max(0, min(srcHeight - 1, floor(y)))
            let x1 = max(0, min(srcWidth - 1, x0 + 1))
            let y1 = max(0, min(srcHeight - 1, y0 + 1))
            let tx = x - x0
            let ty = y - y0

            let c00 = rgba(srcPixels, x: Int(x0), y: Int(y0))
            let c10 = rgba(srcPixels, x: Int(x1), y: Int(y0))
            let c01 = rgba(srcPixels, x: Int(x0), y: Int(y1))
            let c11 = rgba(srcPixels, x: Int(x1), y: Int(y1))

            let mixX1 = c00.0 + (c10.0 - c00.0) * tx
            let mixX2 = c01.0 + (c11.0 - c01.0) * tx
            let mixY = mixX1 + (mixX2 - mixX1) * ty

            let mixX1g = c00.1 + (c10.1 - c00.1) * tx
            let mixX2g = c01.1 + (c11.1 - c01.1) * tx
            let mixYg = mixX1g + (mixX2g - mixX1g) * ty

            let mixX1b = c00.2 + (c10.2 - c00.2) * tx
            let mixX2b = c01.2 + (c11.2 - c01.2) * tx
            let mixYb = mixX1b + (mixX2b - mixX1b) * ty

            let mixX1a = c00.3 + (c10.3 - c00.3) * tx
            let mixX2a = c01.3 + (c11.3 - c01.3) * tx
            let mixYa = mixX1a + (mixX2a - mixX1a) * ty

            return (mixY, mixYg, mixYb, mixYa)
        }

        let fW = srcWidth > 1 ? CGFloat(srcWidth - 1) : 1
        let fH = srcHeight > 1 ? CGFloat(srcHeight - 1) : 1

        for y in 0..<dstHeight {
            for x in 0..<dstWidth {
                let srcX = (CGFloat(x) / CGFloat(max(1, dstWidth - 1))) * fW
                let srcY = (CGFloat(y) / CGFloat(max(1, dstHeight - 1))) * fH

                let sample = sampleBilinear(srcX, srcY)
                let nX = max(0, min(srcWidth - 1, Int(round(srcX))))
                let nY = max(0, min(srcHeight - 1, Int(round(srcY))))
                let nearest = rgba(srcPixels, x: nX, y: nY)

                let lumSample = 0.299 * sample.0 + 0.587 * sample.1 + 0.114 * sample.2
                let lumNearest = 0.299 * nearest.0 + 0.587 * nearest.1 + 0.114 * nearest.2
                let edgeWeight = min(1.0, max(0.0, abs(lumSample - lumNearest) / 40.0))
                let blend = 0.35 * edgeWeight

                let r = sample.0 * (1.0 - blend) + nearest.0 * blend
                let g = sample.1 * (1.0 - blend) + nearest.1 * blend
                let b = sample.2 * (1.0 - blend) + nearest.2 * blend
                let a = sample.3 * (1.0 - blend) + nearest.3 * blend

                let targetIndex = (y * dstWidth + x) * bytesPerPixel
                dstPixels[targetIndex] = clampChannel(r)
                dstPixels[targetIndex + 1] = clampChannel(g)
                dstPixels[targetIndex + 2] = clampChannel(b)
                dstPixels[targetIndex + 3] = clampChannel(a)
            }
        }

        guard let outputCGImage = dstCtx?.makeImage() else { return image }
        return UIImage(cgImage: outputCGImage, scale: 1, orientation: .up)
    }
}
