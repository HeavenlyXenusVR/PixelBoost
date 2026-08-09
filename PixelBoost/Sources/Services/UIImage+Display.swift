import UIKit

extension UIImage {
    /// Returns a copy capped to `maxDimension` on the longest side (`self`
    /// unchanged if already smaller) — for handing a full-resolution
    /// upscale result to an on-screen-only, live/interactive SwiftUI
    /// `Image` (drag-to-compare, pinch-zoom). A tens-of-megapixel UIImage
    /// (a 4x upscale of a modern phone photo easily clears 50MP) fed
    /// straight into such a view measures as torn/sliced into repeating
    /// horizontal bands on real hardware — a CoreAnimation/Metal
    /// large-layer-content rendering artifact triggered by the live
    /// view's own re-composition (drag gesture, pinch, clipping), not a
    /// defect in the pixel data itself: the same `UIImage` saves to Photos
    /// intact. Never apply this to what actually gets saved/exported —
    /// only to a copy created purely for on-screen preview.
    func downsampledForDisplay(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return self }
        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            context.cgContext.interpolationQuality = .high
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
