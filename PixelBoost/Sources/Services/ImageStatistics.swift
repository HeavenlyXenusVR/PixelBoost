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
    /// Mean Laplacian edge response over a desaturated copy — a
    /// no-reference proxy for how much hard line/edge structure (vs. a
    /// smooth photographic gradient) is actually in the frame. Same
    /// desaturate-then-convolve pipeline `sharpnessScore` runs on a
    /// candidate's output, run here on the source instead.
    let edgeDensity: Double

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
            edgeDensity: edgeDensity(of: ciImage)
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

    private static func edgeDensity(of image: CIImage) -> Double {
        guard let grayscale = CIFilter(name: "CIColorControls") else { return 0 }
        grayscale.setValue(image, forKey: kCIInputImageKey)
        grayscale.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let grayImage = grayscale.outputImage else { return 0 }

        guard let laplacian = CIFilter(name: "CIConvolution3X3") else { return 0 }
        laplacian.setValue(grayImage, forKey: kCIInputImageKey)
        laplacian.setValue(CIVector(values: [0, -1, 0, -1, 4, -1, 0, -1, 0], count: 9), forKey: "inputWeights")
        laplacian.setValue(0.0, forKey: "inputBias")
        guard let edges = laplacian.outputImage,
              let pixel = reduce(edges, filterName: "CIAreaAverage", outputWidth: 1) else { return 0 }
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
