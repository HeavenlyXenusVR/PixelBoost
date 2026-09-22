import CoreImage
import UIKit

/// Real per-pixel statistics of a photo — every value here comes from a
/// Core Image reduction filter (`CIAreaAverage`/`CIAreaMinMax`), each of
/// which folds every pixel in the image's extent down to its single output
/// pixel rather than sampling a guess. The same underlying technique
/// `UpscalerProvider.sharpnessScore` already uses to grade a candidate
/// model's *output*; this measures the *source* photo instead, and is
/// shared by `AutoEnhanceService` (exposure/contrast/white-balance) and
/// `UpscalerProvider`'s `.auto` model pick (a content-aware bias on top of
/// its existing output-sharpness trial) — one real measurement of what's
/// actually in the frame, reused everywhere a heuristic needs it.
struct ImageStatistics {
    let meanR: Double
    let meanG: Double
    let meanB: Double
    let minLuma: Double
    let maxLuma: Double
    /// Mean **absolute** Laplacian response over a grayscale copy, on a
    /// 0...255 scale — a no-reference proxy for how much hard line/edge
    /// structure (vs. a smooth photographic gradient) is in the frame.
    /// Same measurement `UpscalerProvider.sharpnessScore` runs on a
    /// candidate's output, via the one shared implementation below.
    ///
    /// The absolute value is not a detail: a Laplacian kernel sums to
    /// zero, so the *signed* mean of its response is ~0 for any image
    /// (measured at ±0.0000 across every test image in
    /// Models/testbench). The previous version averaged the signed
    /// response through Core Image, which measures nothing unless an
    /// intermediate happens to clamp the negative lobes away — behavior
    /// that depends on CIContext's working format rather than on
    /// anything in the photo.
    let edgeEnergy: Double

    var meanLuma: Double { 0.2126 * meanR + 0.7152 * meanG + 0.0722 * meanB }

    /// How far apart the three channel means are — near 0 for
    /// grayscale-ish content (a scanned document, a black-and-white
    /// photo), higher for a saturated color photo or colorful
    /// illustration.
    var channelSpread: Double { max(meanR, meanG, meanB) - min(meanR, meanG, meanB) }

    // No color management: these are raw intensity reads for statistics,
    // not display-ready colors — same reasoning as `sharpnessScore`'s
    // own context.
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func measure(_ image: UIImage) -> ImageStatistics? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        guard let average = reduce(ciImage, filterName: "CIAreaAverage", outputWidth: 1),
              let minMax = reduce(ciImage, filterName: "CIAreaMinMax", outputWidth: 2) else { return nil }

        let minPixel = Array(minMax[0..<4])
        let maxPixel = Array(minMax[4..<8])
        let minLuma = luma(minPixel)
        return ImageStatistics(
            meanR: Double(average[0]) / 255, meanG: Double(average[1]) / 255, meanB: Double(average[2]) / 255,
            minLuma: minLuma, maxLuma: max(luma(maxPixel), minLuma + 0.05),
            edgeEnergy: edgeEnergy(of: image)
        )
    }

    private static func reduce(_ image: CIImage, filterName: String, outputWidth: Int) -> [UInt8]? {
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: "inputExtent")
        guard let output = filter.outputImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: outputWidth * 4)
        context.render(
            output, toBitmap: &pixels, rowBytes: outputWidth * 4,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: 1), format: .RGBA8, colorSpace: nil
        )
        return pixels
    }

    private static func luma(_ pixel: [UInt8]) -> Double {
        (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    /// Mean absolute 3x3 Laplacian over a grayscale copy, 0...255 — the
    /// single implementation behind both this type's `edgeEnergy` and
    /// `UpscalerProvider.sharpnessScore`, so a source measurement and a
    /// candidate's score are always in the same units.
    ///
    /// Done as an explicit pixel pass rather than
    /// CIConvolution3X3 + CIAreaAverage. Core Image keeps intermediates in
    /// half-float, so the convolution's negative lobes survive into the
    /// average and cancel the positive ones almost exactly; whether any
    /// step clamps them away is a property of the context's working
    /// format, not of the image. A loop over the bytes has no such
    /// ambiguity, costs little at these sizes, and produces the same
    /// number on every device.
    ///
    /// Reference values from Models/testbench (256px center crops):
    /// a flat/dark poster ~1.3, an ordinary photo ~4, this app's own
    /// 3D-render screenshots 9-13, a dense poster ~26. Model outputs of a
    /// 320px crop at 4x: plain resize ~1.3, Real-ESRGAN family 3.3-4.4.
    static func edgeEnergy(of image: UIImage, maxDimension: Int = 1024) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        // Measured on a bounded copy: a 4x upscale of a big photo can be
        // 48MP, and every candidate in a comparison is the same size, so
        // capping keeps the score cheap without making it unfair.
        let longest = max(cgImage.width, cgImage.height)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1
        let width = max(3, Int(Double(cgImage.width) * scale))
        let height = max(3, Int(Double(cgImage.height) * scale))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            luma[i] = 0.2126 * Double(pixels[o]) + 0.7152 * Double(pixels[o + 1]) + 0.0722 * Double(pixels[o + 2])
        }

        // Interior pixels only — the border would need edge replication to
        // contribute a meaningful response, and at these sizes one ring of
        // pixels can't move the mean.
        var total = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let response = 4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - width] - luma[i + width]
                total += abs(response)
            }
        }
        return total / Double((width - 2) * (height - 2))
    }
}
