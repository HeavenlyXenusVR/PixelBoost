import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Flips a normal map between OpenGL convention (green channel points "up",
/// what Blender exports by default) and DirectX convention (green
/// inverted — what Unity/Unreal/most game engines expect) — a real,
/// specific round-trip pain point for anyone moving a texture between
/// Blender and a game engine, not a general photo-editing operation. Pure
/// `CIColorMatrix` (green' = 1 - green, every other channel untouched); no
/// model, no ML, same "classical where sensible" reasoning as
/// `PhotoAdjustments`/`PhotoFilter`.
enum NormalMapService {
    private static let context = CIContext()

    static func flipGreenChannel(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = ciImage
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 1, z: 0, w: 0)

        guard let output = matrix.outputImage,
              let rendered = context.createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
