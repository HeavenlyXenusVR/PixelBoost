import CoreImage
import UIKit

/// One-tap automatic exposure/contrast/color-cast correction, driven by
/// real measurements of every pixel in the photo (`ImageStatistics`)
/// rather than Apple's opaque `autoAdjustmentFilters` heuristic. Red-eye
/// correction still comes from that API (Vision-based face detection,
/// nothing worth reimplementing there) — everything else is computed from
/// this specific photo's own measured brightness, contrast range, and
/// per-channel color balance:
///
/// - **Exposure**: nudges the measured mean luminance toward a mid-gray
///   target, in EV, clamped so a already-well-exposed photo isn't touched
///   and an extreme (near-black/near-white) one isn't blown out chasing
///   an unreachable target.
/// - **Contrast**: only boosted when the measured luminance range (min to
///   max, across the whole frame) is actually narrow — a flat/hazy
///   photo — left alone when it's already wide.
/// - **White balance**: a damped gray-world correction (each channel
///   nudged a fraction of the way toward the average of all three) from
///   the photo's own measured per-channel means, not a fixed preset.
enum AutoEnhanceService {
    private static let context = CIContext()

    static func enhance(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)

        // Red-eye only — the exposure/contrast/color-balance passes below
        // replace `.enhance`'s own opaque heuristic with ones driven by
        // this photo's actual measured pixel statistics.
        var output = ciImage
        for filter in ciImage.autoAdjustmentFilters(options: [.redEye: true]) {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let result = filter.outputImage { output = result }
        }

        if let stats = ImageStatistics.measure(image) {
            output = applyExposure(to: output, stats: stats)
            output = applyContrast(to: output, stats: stats)
            output = applyWhiteBalance(to: output, stats: stats)
        }

        guard let rendered = context.createCGImage(output, from: ciImage.extent) else { return image }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    /// Targets a mid-gray (0.45) mean luminance — under- or over-exposed
    /// by more than roughly a third of a stop gets corrected; anything
    /// closer than that is left alone rather than chasing the target
    /// exactly, since a small nudge on an already-fine exposure is more
    /// likely to look like drift than an improvement.
    private static func applyExposure(to image: CIImage, stats: ImageStatistics) -> CIImage {
        let targetMean = 0.45
        let ev = log2(targetMean / max(stats.meanLuma, 0.02))
        let clampedEV = max(-1.0, min(ev, 1.2))
        guard abs(clampedEV) > 0.05, let filter = CIFilter(name: "CIExposureAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(clampedEV), forKey: "inputEV")
        return filter.outputImage ?? image
    }

    /// `stats.maxLuma - stats.minLuma` is the measured tonal range of the
    /// whole frame — below 0.6 (out of a possible 1.0) reads as flat/hazy
    /// and gets a proportional contrast boost, capped at +35% so a very
    /// flat scan or foggy photo doesn't get crushed.
    private static func applyContrast(to image: CIImage, stats: ImageStatistics) -> CIImage {
        let range = max(0.05, stats.maxLuma - stats.minLuma)
        guard range < 0.6, let filter = CIFilter(name: "CIColorControls") else { return image }
        let boost = 1.0 + min(0.35, (0.6 - range) * 0.6)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(boost), forKey: kCIInputContrastKey)
        return filter.outputImage ?? image
    }

    /// Gray-world white balance: if every channel averaged the same, the
    /// photo has no overall color cast. `stats.meanR/G/B` measure whether
    /// that's actually true here, and each channel gets scaled a fraction
    /// (35%) of the way toward the three-channel average — a full
    /// correction would neutralize intentional warm/cool color grading
    /// (a sunset, a blue-hour shot); a partial one only tempers a genuine
    /// cast (a fluorescent-lit indoor photo, a foggy blue-gray day)
    /// without flattening deliberate color.
    private static func applyWhiteBalance(to image: CIImage, stats: ImageStatistics) -> CIImage {
        let gray = (stats.meanR + stats.meanG + stats.meanB) / 3
        guard gray > 0.02, let filter = CIFilter(name: "CIColorMatrix") else { return image }

        func dampedScale(_ channelMean: Double) -> Double {
            let raw = gray / max(channelMean, 0.02)
            let damped = 1 + (raw - 1) * 0.35
            return max(0.85, min(damped, 1.18))
        }

        let rScale = dampedScale(stats.meanR)
        let gScale = dampedScale(stats.meanG)
        let bScale = dampedScale(stats.meanB)
        guard max(abs(rScale - 1), abs(gScale - 1), abs(bScale - 1)) > 0.02 else { return image }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: CGFloat(rScale), y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: CGFloat(gScale), z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: CGFloat(bScale), w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return filter.outputImage ?? image
    }
}
