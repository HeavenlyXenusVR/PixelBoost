import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Depth-based fog/haze compositing, using a companion depth (Z) pass —
/// see `EXRDecoder.decodeEXRDepth`/`EXRImportService.loadDepthImage`. Real
/// depth data, not a plausibility guess the way a single-image "portrait
/// mode" blur has to be: `CIBlendWithMask` composites the original (near,
/// sharp) over a solid fog color (far, obscured) using the depth pass
/// directly as the mask — near=bright=shows original, far=dark=shows fog,
/// exactly the convention `decodeEXRDepth` already encodes.
enum DepthFogService {
    private static let context = CIContext()

    /// - Parameter depthMask: from `EXRImportService.loadDepthImage` — near
    ///   pixels bright, far pixels dark. Must be the same pixel dimensions
    ///   as `image`.
    /// - Parameter intensity: 0...1. 0 leaves `image` untouched; 1 uses the
    ///   depth mask at full strength. Implemented as a lerp between the
    ///   depth mask and an all-white ("no fog anywhere") mask, not a
    ///   mask-value power curve — keeps the falloff shape depth-accurate
    ///   at every intensity, just dials how far it reaches.
    /// - Parameter fogColor: solid color standing in for atmospheric haze.
    static func applyFog(_ image: UIImage, depthMask: UIImage, intensity: Double, fogColor: UIColor) -> UIImage {
        guard intensity > 0, let cgImage = image.cgImage, let maskCG = depthMask.cgImage else { return image }
        let foreground = CIImage(cgImage: cgImage)
        var mask = CIImage(cgImage: maskCG)

        // Resize the mask to match, in case the depth pass and beauty pass
        // weren't rendered at identical resolutions (a real possibility —
        // render engines commonly let AOV passes use a different output
        // size than the main beauty pass).
        if mask.extent.size != foreground.extent.size, mask.extent.width > 0, mask.extent.height > 0 {
            let scaleX = foreground.extent.width / mask.extent.width
            let scaleY = foreground.extent.height / mask.extent.height
            mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        if intensity < 1 {
            let allWhite = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: mask.extent)
            let lerp = CIFilter.blendWithAlphaMask()
            // Reuses blendWithAlphaMask as a two-image lerp: alpha-mask
            // blend of (depth mask) over (all-white), driven by a constant
            // alpha plane at `intensity` — cheaper than building a custom
            // CIKernel just for a per-pixel lerp between two grayscale
            // images.
            lerp.inputImage = mask
            lerp.backgroundImage = allWhite
            lerp.maskImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(intensity))).cropped(to: mask.extent)
            if let output = lerp.outputImage {
                mask = output
            }
        }

        let fog = CIImage(color: CIColor(
            red: fogColor.cgColor.components?[0] ?? 0.7,
            green: fogColor.cgColor.components?[1] ?? 0.75,
            blue: fogColor.cgColor.components?[2] ?? 0.8
        )).cropped(to: foreground.extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = fog
        blend.maskImage = mask

        guard let output = blend.outputImage,
              let rendered = context.createCGImage(output, from: foreground.extent) else {
            return image
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
