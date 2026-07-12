import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// A one-tap look applied over the current photo. Built entirely from
/// Core Image's built-in "photo effect" filters — fixed, parameterless
/// Apple presets, the same filters behind Photos' own filter picker — plus
/// two filters with a single, one-directional intensity (`CISepiaTone`,
/// and a hand-tuned "Vivid" via `CIColorControls`). Nothing here has a
/// sign/direction that could be guessed wrong without a real device to
/// check against, unlike e.g. a white-balance tint.
enum PhotoFilter: String, CaseIterable, Identifiable {
    case none
    case vivid
    case mono
    case noir
    case tonal
    case chrome
    case process
    case transfer
    case instant
    case fade
    case sepia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .tonal: return "Silvertone"
        case .chrome: return "Chrome"
        case .process: return "Process"
        case .transfer: return "Transfer"
        case .instant: return "Instant"
        case .fade: return "Fade"
        case .sepia: return "Sepia"
        }
    }

    private static let context = CIContext()

    /// Renders this filter onto `image`. Returns `image` unchanged for
    /// `.none` rather than round-tripping it through Core Image for
    /// nothing.
    func apply(to image: UIImage) -> UIImage {
        guard self != .none, let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let output: CIImage?

        switch self {
        case .none:
            output = ciImage
        case .vivid:
            let filter = CIFilter.colorControls()
            filter.inputImage = ciImage
            filter.saturation = 1.35
            filter.contrast = 1.12
            output = filter.outputImage
        case .mono:
            let filter = CIFilter.photoEffectMono()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .noir:
            let filter = CIFilter.photoEffectNoir()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .tonal:
            let filter = CIFilter.photoEffectTonal()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .chrome:
            let filter = CIFilter.photoEffectChrome()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .process:
            let filter = CIFilter.photoEffectProcess()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .transfer:
            let filter = CIFilter.photoEffectTransfer()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .instant:
            let filter = CIFilter.photoEffectInstant()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .fade:
            let filter = CIFilter.photoEffectFade()
            filter.inputImage = ciImage
            output = filter.outputImage
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = ciImage
            filter.intensity = 0.85
            output = filter.outputImage
        }

        // Extent, not `.zero`-origin image.size — none of these filters
        // shift the origin, but relying on that rather than assuming is
        // one less thing to get wrong blind.
        guard let output, let rendered = Self.context.createCGImage(output, from: ciImage.extent) else {
            return image
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
