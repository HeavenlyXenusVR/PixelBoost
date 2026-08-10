import CoreImage
import UIKit
import Vision

enum BackgroundRemovalError: LocalizedError {
    case noSubjectDetected
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .noSubjectDetected:
            return "No distinct subject was found in this photo to cut out."
        case .processingFailed:
            return "Couldn't process this photo's background."
        }
    }
}

/// Cuts the main subject(s) out of a photo using Vision's on-device subject
/// segmentation (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+) — the
/// same technology behind Photos' own "Lift Subject" long-press. There's no
/// custom model to source, convert, or bundle here, unlike the upscaling
/// models in `Models/` — Vision ships this on every iOS 17 device.
enum BackgroundRemovalService {
    /// Returns a new image, the same pixel dimensions as `image`, with
    /// everything Vision didn't consider part of the main subject(s) made
    /// transparent. Throws `BackgroundRemovalError.noSubjectDetected` if
    /// Vision doesn't find anything to lift out (e.g. a flat texture or
    /// sky with no distinct foreground object).
    static func removeBackground(from image: UIImage) async throws -> UIImage {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }
        // VNImageRequestHandler.perform runs synchronously and can take
        // real time — same reasoning as CoreMLTileUpscaler's model calls,
        // dispatch off whatever cooperative-pool thread is awaiting this.
        return try await Task.detached(priority: .userInitiated) {
            try cutoutSubject(from: cgImage)
        }.value
    }

    private static func cutoutSubject(from cgImage: CGImage) throws -> UIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw BackgroundRemovalError.noSubjectDetected
        }

        // A single-channel mask (white over every detected subject
        // instance, black elsewhere), already resolved back to the
        // original image's own dimensions regardless of whatever internal
        // resolution Vision actually ran the segmentation network at.
        let maskBuffer = try result.generateMaskedImage(
            ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false
        )
        return try composite(maskImage: CIImage(cvPixelBuffer: maskBuffer), over: cgImage)
    }

    private static func composite(maskImage: CIImage, over cgImage: CGImage) throws -> UIImage {
        let subjectImage = CIImage(cgImage: cgImage)

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw BackgroundRemovalError.processingFailed
        }
        // CIBlendWithMask: input shows through where the mask is white,
        // background shows through where the mask is black — a fully
        // transparent CIImage as the background is what turns the masked-
        // out area into real alpha rather than a solid fill color.
        blend.setValue(subjectImage, forKey: kCIInputImageKey)
        blend.setValue(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: subjectImage.extent),
            forKey: kCIInputBackgroundImageKey
        )
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)

        guard let output = blend.outputImage else { throw BackgroundRemovalError.processingFailed }

        let context = CIContext()
        guard let rendered = context.createCGImage(
            output, from: subjectImage.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw BackgroundRemovalError.processingFailed
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    // -------------------------------------------------------------------
    // Tap to Select — a specific detected instance, not "every subject"
    // -------------------------------------------------------------------
    //
    // `VNGenerateForegroundInstanceMaskRequest` already segments each
    // distinct foreground object separately (background=0, each subject
    // labeled 1, 2, 3, ... — `removeBackground(from:)` above just merges
    // every one of them via `allInstances`). This reuses the exact same
    // request/result type to expose per-instance masks instead, so a tap
    // can pick out one specific object (a person in a group photo, one
    // item on a table) rather than everything foreground at once.

    struct DetectedInstance: Identifiable {
        let id: Int
        /// Single-channel (`OneComponent8`), same pixel dimensions as the
        /// source image — 255 where this one instance is, 0 elsewhere.
        let maskBuffer: CVPixelBuffer
    }

    struct InstanceDetectionResult {
        let cgImage: CGImage
        let instances: [DetectedInstance]
    }

    /// Runs the same Vision request `removeBackground(from:)` does, but
    /// keeps every detected instance's own individual mask instead of
    /// merging them — one `generateMaskedImage` call per instance
    /// (cheap: post-processing over already-computed internal instance
    /// data, not a second run of the segmentation network itself).
    static func detectInstances(in image: UIImage) async throws -> InstanceDetectionResult {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                throw BackgroundRemovalError.noSubjectDetected
            }
            let instances = try result.allInstances.map { index -> DetectedInstance in
                let buffer = try result.generateMaskedImage(
                    ofInstances: [index], from: handler, croppedToInstancesExtent: false
                )
                return DetectedInstance(id: index, maskBuffer: buffer)
            }
            return InstanceDetectionResult(cgImage: cgImage, instances: instances)
        }.value
    }

    /// Which detected instance (if any) covers `imagePoint` — in the
    /// source image's own pixel coordinates, top-left origin, y-down (same
    /// convention as `ImageTiler`/`UIImage.cropped(to:)`, NOT Core Image's
    /// bottom-left/y-up space). Checks instances in detection order and
    /// returns the first match, which in practice means the
    /// larger/more-confident instance wins on any pixel two overlapping
    /// subjects' masks both cover.
    static func instance(at imagePoint: CGPoint, in result: InstanceDetectionResult) -> DetectedInstance? {
        result.instances.first { maskValue(at: imagePoint, in: $0.maskBuffer) > 128 }
    }

    /// Cuts just `instance` out — same alpha-matte compositing
    /// `removeBackground(from:)` uses, just handed one instance's mask
    /// directly instead of computing a combined one.
    static func cutout(_ instance: DetectedInstance, from cgImage: CGImage) throws -> UIImage {
        try composite(maskImage: CIImage(cvPixelBuffer: instance.maskBuffer), over: cgImage)
    }

    private static func maskValue(at point: CGPoint, in buffer: CVPixelBuffer) -> UInt8 {
        let x = Int(point.x)
        let y = Int(point.y)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        return row[x]
    }
}
