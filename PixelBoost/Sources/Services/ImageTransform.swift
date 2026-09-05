import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Rotate/flip helpers for `CropRotateView` — crop itself reuses the
/// existing `UIImage.cropped(to:)` extension from `UIImage+Tile.swift`,
/// same top-left-origin pixel-rect convention.
///
/// Every renderer here uses `format.opaque = false` deliberately — these
/// tools chain onto whatever the current image already is (see
/// `UpscalerViewModel`'s `currentWorkingImage`), which after a Cutout run
/// has real transparency. An opaque render would silently flatten that to
/// black.
enum ImageTransform {
    static func rotated90(_ image: UIImage, clockwise: Bool) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let upright = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        let newSize = CGSize(width: image.size.height, height: image.size.width)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            // A CGContext inside UIGraphicsImageRenderer already matches
            // UIKit's own view coordinate space (Y down), where a positive
            // rotation angle appears clockwise on screen — the same
            // convention `CGAffineTransform(rotationAngle:)` uses for a
            // `UIView.transform`. If "rotate right" ever turns out to spin
            // the wrong way on a real device, flip the sign here first.
            context.cgContext.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            let drawRect = CGRect(
                x: -image.size.width / 2, y: -image.size.height / 2,
                width: image.size.width, height: image.size.height
            )
            upright.draw(in: drawRect)
        }
    }

    static func flippedHorizontally(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let upright = UIImage(cgImage: cgImage, scale: 1, orientation: .up)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: image.size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            upright.draw(at: .zero)
        }
    }

    static func flippedVertically(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let upright = UIImage(cgImage: cgImage, scale: 1, orientation: .up)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: 0, y: image.size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            upright.draw(at: .zero)
        }
    }

    /// Applies a pixel-by-pixel anti-alias pass that analyzes each RGBA
    /// pixel and its neighbors, smoothing only low-contrast stair-step
    /// regions while preserving strong edges. This follows the app's own
    /// raw-pixel processing pattern more closely than a generic blur and is
    /// safe for any image size or source, not just large upscaled outputs.
    static func antiAliased(_ image: UIImage, amount: Double) -> UIImage {
        let strength = max(0, min(1, amount))
        guard strength > 0 else { return image }
        guard let cgImage = image.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = height * bytesPerRow

        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        sourceBuffer.initialize(repeating: 0, count: byteCount)
        defer { sourceBuffer.deallocate() }

        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        outputBuffer.initialize(repeating: 0, count: byteCount)
        defer { outputBuffer.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let sourceContext = CGContext(
            data: sourceBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let radius = 1
        let threshold = 0.08 + (1 - strength) * 0.06

        for y in 0..<height {
            for x in 0..<width {
                let centerIndex = (y * width + x) * bytesPerPixel
                let centerR = Double(sourceBuffer[centerIndex])
                let centerG = Double(sourceBuffer[centerIndex + 1])
                let centerB = Double(sourceBuffer[centerIndex + 2])
                let centerA = Double(sourceBuffer[centerIndex + 3])

                var sumR = 0.0, sumG = 0.0, sumB = 0.0
                var count = 0
                var edgeScore = 0.0

                for offsetY in -radius...radius {
                    let ny = y + offsetY
                    guard ny >= 0, ny < height else { continue }
                    for offsetX in -radius...radius {
                        let nx = x + offsetX
                        guard nx >= 0, nx < width else { continue }
                        let index = (ny * width + nx) * bytesPerPixel
                        sumR += Double(sourceBuffer[index])
                        sumG += Double(sourceBuffer[index + 1])
                        sumB += Double(sourceBuffer[index + 2])
                        count += 1

                        let neighborLum = 0.299 * Double(sourceBuffer[index])
                            + 0.587 * Double(sourceBuffer[index + 1])
                            + 0.114 * Double(sourceBuffer[index + 2])
                        let centerLum = 0.299 * centerR + 0.587 * centerG + 0.114 * centerB
                        edgeScore += abs(neighborLum - centerLum)
                    }
                }

                let averageR = sumR / Double(max(1, count))
                let averageG = sumG / Double(max(1, count))
                let averageB = sumB / Double(max(1, count))
                let avgEdge = edgeScore / Double(max(1, count))
                let localContrast = min(1, avgEdge / 32.0)
                let blend = strength * max(0, 1.0 - max(localContrast, threshold))

                outputBuffer[centerIndex] = UInt8((centerR * (1 - blend) + averageR * blend).rounded())
                outputBuffer[centerIndex + 1] = UInt8((centerG * (1 - blend) + averageG * blend).rounded())
                outputBuffer[centerIndex + 2] = UInt8((centerB * (1 - blend) + averageB * blend).rounded())
                outputBuffer[centerIndex + 3] = UInt8(centerA)
            }
        }

        guard let outputContext = CGContext(
            data: outputBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        guard let outputCGImage = outputContext.makeImage() else { return image }

        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
