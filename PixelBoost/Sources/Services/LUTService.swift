import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Parses and applies a standard `.cube` 3D LUT — the Adobe/Iridas format
/// most color-grading tools (DaVinci Resolve, Blender's own LUT export
/// add-ons, most render engines' color pipelines) can export, and a
/// completely different kind of "look" than this app's existing Filters
/// tab: a LUT is an externally-authored grade brought in from outside the
/// app, not one of PixelBoost's own thirteen fixed presets. Backed by
/// `CIColorCube`, a native Core Image filter — no model, no vendored
/// parser library, unlike EXR import.
enum LUTService {
    struct LUT {
        let dimension: Int
        /// Flat RGBA float32 array, `dimension^3` entries, red
        /// fastest-varying — exactly `CIColorCube`'s `inputCubeData` layout,
        /// so no repacking is needed between parse and apply.
        let data: [Float]
    }

    enum LUTError: LocalizedError {
        case missingSize
        case malformedEntry(line: Int)
        case entryCountMismatch(expected: Int, found: Int)

        var errorDescription: String? {
            switch self {
            case .missingSize:
                return "This .cube file has no LUT_3D_SIZE line — not a valid 3D LUT."
            case .malformedEntry(let line):
                return "Couldn't read the color values on line \(line) of this .cube file."
            case .entryCountMismatch(let expected, let found):
                return "This .cube file claims \(expected) entries but only has \(found) — it may be truncated."
            }
        }
    }

    /// Parses `.cube` text: `LUT_3D_SIZE N` declares the dimension, then
    /// N^3 lines of `r g b` floats (0...1) follow, red fastest-varying —
    /// `TITLE`/`DOMAIN_MIN`/`DOMAIN_MAX` lines and `#`-comments are
    /// skipped. `DOMAIN_MIN`/`DOMAIN_MAX` (a rescale of the input range,
    /// occasionally non-default in exported LUTs) is intentionally not
    /// applied — same "keep the common case correct and simple" tradeoff
    /// as everywhere else classical-CV in this app; a LUT using a
    /// non-[0,1] domain will look off.
    static func parse(_ text: String) throws -> LUT {
        var dimension: Int?
        var entries: [Float] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            // .whitespacesAndNewlines, not just .whitespaces — a
            // Windows-authored .cube (common; DaVinci Resolve runs on
            // Windows) uses "\r\n" line endings, and splitting on "\n"
            // alone leaves a trailing "\r" that plain .whitespaces doesn't
            // strip, which would otherwise corrupt every LUT_3D_SIZE parse
            // and the last float of every color-triple line.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let n = Int(parts[1]) {
                    dimension = n
                }
                continue
            }
            // Any other keyword line (TITLE, DOMAIN_MIN, DOMAIN_MAX,
            // LUT_1D_SIZE — a 1D LUT isn't supported here) — skip rather
            // than fail, keyword lines don't start with a digit/minus sign
            // the way a color triple does.
            guard let first = line.first, first.isNumber || first == "-" || first == "." else { continue }

            let components = line.split(separator: " ").compactMap { Float($0) }
            guard components.count == 3 else {
                throw LUTError.malformedEntry(line: index + 1)
            }
            entries.append(contentsOf: components)
            entries.append(1.0)  // alpha — CIColorCube expects RGBA per entry
        }

        guard let dimension else { throw LUTError.missingSize }
        let expectedEntryCount = dimension * dimension * dimension * 4
        guard entries.count == expectedEntryCount else {
            throw LUTError.entryCountMismatch(expected: expectedEntryCount / 4, found: entries.count / 4)
        }
        return LUT(dimension: dimension, data: entries)
    }

    private static let context = CIContext()

    /// - Parameter intensity: 0...1, a dissolve between the untouched
    ///   original and the fully-graded result — `CIColorCube` itself has
    ///   no strength knob (it's a straight-through 3D lookup), so partial
    ///   strength is a separate crossfade, not the filter's own doing.
    static func apply(_ lut: LUT, to image: UIImage, intensity: Double) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let source = CIImage(cgImage: cgImage)

        let cube = CIFilter.colorCube()
        cube.inputImage = source
        cube.cubeDimension = Float(lut.dimension)
        cube.cubeData = lut.data.withUnsafeBufferPointer { Data(buffer: $0) }

        guard let graded = cube.outputImage else { return image }

        let composited: CIImage
        if intensity >= 1 {
            composited = graded
        } else {
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = source
            dissolve.targetImage = graded
            dissolve.time = Float(intensity)
            composited = dissolve.outputImage ?? graded
        }

        guard let rendered = context.createCGImage(composited, from: source.extent) else { return image }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}
