import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Multiplies a companion Ambient Occlusion pass onto the beauty image —
/// see `EXRDecoder.decodeEXRMask`/`EXRImportService.loadMaskImage`. A cheap,
/// standard compositing trick real render pipelines use too (baking a
/// separately-rendered/denoised AO pass back in at comp time, rather than
/// only ever getting occlusion "for free" and unadjustable from the beauty
/// render) — darkens contact shadows/creases without a second full render.
enum AOBlendService {
    private static let context = CIContext()

    /// - Parameter intensity: 0...1 — 0 leaves `image` untouched, 1 uses
    ///   the AO pass at full strength (a straight multiply). Implemented as
    ///   a lerp between the AO mask and an all-white ("no occlusion
    ///   anywhere") mask, same reasoning as `DepthFogService.applyFog`'s
    ///   intensity parameter — keeps the occlusion *shape* accurate at
    ///   every intensity, just dials how dark it gets.
    static func applyAO(_ image: UIImage, aoMask: UIImage, intensity: Double) -> UIImage {
        guard intensity > 0, let cgImage = image.cgImage, let maskCG = aoMask.cgImage else { return image }
        let foreground = CIImage(cgImage: cgImage)
        var mask = CIImage(cgImage: maskCG)

        if mask.extent.size != foreground.extent.size, mask.extent.width > 0, mask.extent.height > 0 {
            let scaleX = foreground.extent.width / mask.extent.width
            let scaleY = foreground.extent.height / mask.extent.height
            mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        if intensity < 1 {
            let allWhite = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: mask.extent)
            let lerp = CIFilter.blendWithAlphaMask()
            lerp.inputImage = mask
            lerp.backgroundImage = allWhite
            lerp.maskImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(intensity))).cropped(to: mask.extent)
            if let output = lerp.outputImage {
                mask = output
            }
        }

        let multiply = CIFilter.multiplyBlendMode()
        multiply.inputImage = mask
        multiply.backgroundImage = foreground

        guard let output = multiply.outputImage,
              let rendered = context.createCGImage(output, from: foreground.extent) else {
            return image
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
