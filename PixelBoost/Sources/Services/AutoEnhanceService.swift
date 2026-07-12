import CoreImage
import UIKit

/// One-tap automatic exposure/color correction — Core Image's own
/// `autoAdjustmentFilters`, the same histogram-based auto-analysis API
/// iOS has shipped since iOS 5 (auto level/vibrance, plus red-eye
/// correction when a face is detected). No custom model or manual
/// sliders involved: this is exactly what Snapseed's "Tune Image" auto
/// button and Photoshop Express's "Auto Enhance" do under the hood.
enum AutoEnhanceService {
    private static let context = CIContext()

    static func enhance(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)

        // Filters come back each still pointed at `ciImage` as their
        // input — chaining them means re-pointing each one at the
        // previous filter's output in turn, the standard documented
        // pattern for this API (it doesn't chain them for you).
        let filters = ciImage.autoAdjustmentFilters(options: [
            .enhance: true,
            .redEye: true,
        ])
        var output = ciImage
        for filter in filters {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let result = filter.outputImage {
                output = result
            }
        }

        guard let rendered = context.createCGImage(output, from: ciImage.extent) else { return image }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
