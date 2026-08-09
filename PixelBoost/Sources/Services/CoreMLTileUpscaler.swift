import CoreImage
import CoreML
import Foundation
import UIKit
import Vision

/// Runs a bundled Core ML super-resolution model (e.g. a converted
/// Real-ESRGAN) over an image, tile by tile via `ImageTiler`, and stitches
/// the results back together. See Models/README.md for how to obtain/convert
/// a model and what `tileSize`/`scaleFactor` need to match it.
final class CoreMLTileUpscaler: ImageUpscaling {
    struct Config {
        /// Must match the model's fixed input width/height in pixels.
        var tileSize: Int = 128
        /// Must match the model's output-size-to-input-size ratio.
        var scaleFactor: Int = 4
        /// Context pixels fed to the model on each side of a tile beyond
        /// what's actually kept — improves quality right at tile borders.
        /// Larger costs more compute per tile for (usually) diminishing
        /// returns; 8-16 is a reasonable range for a 128px tile.
        var overlap: Int = 8
    }

    private let visionModel: VNCoreMLModel
    private let modelName: String
    /// Mutable (not just at init) so `UpscalerProvider` can adjust overlap
    /// for a quality-preset change without re-loading the underlying
    /// `MLModel` — that load is the expensive part (real I/O + mmap), not
    /// this struct.
    private(set) var config: Config
    var techniqueInfo: UpscaleTechniqueInfo {
        UpscaleTechniqueInfo(
            technique: "coreml_tile", modelName: modelName,
            tileSize: config.tileSize, overlap: config.overlap, scaleFactor: config.scaleFactor
        )
    }
    // workingColorSpace: NSNull() disables Core Image's color management for
    // this context. The model was trained on plain 0-255 RGB byte arrays
    // with no notion of a color profile — with color management left on,
    // Core Image re-tags/gamma-corrects the model's raw output pixel buffer
    // against a working color space when converting it back to a CGImage,
    // which shows up as a washed-out/lower-contrast haze over otherwise
    // genuinely-sharper detail (this exact symptom, reported after the
    // first real on-device test). Disabling it makes pixel values pass
    // through numerically unchanged, matching what the model actually
    // produced.
    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
    ])

    /// - Parameter modelName: the compiled model's filename without
    ///   extension, as it appears in the app bundle (i.e. what a
    ///   `<name>.mlmodel` dropped in Models/ compiles to). Throws
    ///   `UpscaleError.modelNotBundled` if it isn't present — callers should
    ///   fall back to `LanczosUpscaler` in that case.
    init(modelName: String = "RealESRGAN", config: Config = Config()) throws {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw UpscaleError.modelNotBundled(modelName)
        }
        // Default (.all) compute units — a real-device A/B test proved the
        // corruption reported below is 100% independent of compute
        // backend: a CPU-only run (v3.22.3) produced pixel-identical
        // corrupted output to an earlier .cpuAndGPU run (v3.22.1) of the
        // same photo. That rules out GPU/ANE/any hardware race entirely —
        // the bug is fully deterministic, so it has to be in this file's
        // own tile-compositing code (see `upscale(_:progress:)` below) or
        // the model conversion, not the runtime. No reason to keep paying
        // CPU-only's real speed cost once the backend was cleared.
        let mlModel = try MLModel(contentsOf: url)
        self.visionModel = try VNCoreMLModel(for: mlModel)
        self.modelName = modelName
        self.config = config
    }

    /// Adjusts context-tile overlap (e.g. for a quality-preset change)
    /// without reconstructing this instance or reloading the model.
    func updateOverlap(_ overlap: Int) {
        config.overlap = overlap
    }

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }
        let tiler = ImageTiler(tileSize: config.tileSize, overlap: config.overlap, scaleFactor: config.scaleFactor)
        let plan = tiler.plan(imageWidth: cgImage.width, imageHeight: cgImage.height)

        // Normalize once so every tile crop is a plain 1-point-per-pixel,
        // upright image — see UIImage+Tile.swift for why this matters.
        let normalized = UIImage(cgImage: cgImage, scale: 1, orientation: .up)

        // Collected in memory and stitched via UIGraphicsImageRenderer once
        // every tile is done, NOT drawn incrementally into one shared
        // CGContext with a manual bottom-left-to-top-left coordinate flip
        // (translateBy/scaleBy) — that manual-flip version shipped without
        // ever running on real hardware and was the actual source of a
        // reported export corruption bug (torn into repeating horizontal
        // bands — every tile row landing at a subtly wrong Y). A real
        // device A/B test proved the corruption was 100% deterministic and
        // independent of compute backend (CPU-only vs GPU+ANE gave
        // pixel-identical corrupted output), which rules out a hardware
        // race and points squarely at this file's own compositing math.
        // UIGraphicsImageRenderer/UIImage.draw(at:) handle the coordinate
        // system entirely internally — no hand-rolled CTM flip to get
        // subtly wrong — at the cost of holding every tile's cropped
        // output in memory simultaneously until the final stitch (the
        // original, deliberate memory/crash tradeoff this was rewritten
        // away from; see README's "no disk-based caching of intermediate
        // tiles" known simplification).
        var results: [(destOrigin: CGPoint, croppedOutput: UIImage)] = []
        results.reserveCapacity(plan.tiles.count)

        for (index, tile) in plan.tiles.enumerated() {
            try Task.checkCancellation()
            // Edge-replicated, not a plain `cropped(to:)` — a tile
            // touching the photo's outer border needs its `overlap`-pixel
            // margin to be real (if flat) context, not a hard transparent
            // edge; see `croppedEdgeReplicated(to:)`'s doc comment for the
            // measured dark/smudged-fringe defect this fixes.
            let inputTile = normalized.croppedEdgeReplicated(to: tile.sourceRect)
            let outputTile = try await runModel(on: inputTile)

            let keepScaled = CGRect(
                x: tile.keepRect.origin.x * CGFloat(config.scaleFactor),
                y: tile.keepRect.origin.y * CGFloat(config.scaleFactor),
                width: tile.keepRect.width * CGFloat(config.scaleFactor),
                height: tile.keepRect.height * CGFloat(config.scaleFactor)
            )
            let croppedOutput = outputTile.cropped(to: keepScaled)
            results.append((tile.destOrigin, croppedOutput))
            progress(Double(index + 1) / Double(plan.tiles.count))
        }

        let stitched = Self.stitch(results, canvasSize: plan.outputSize)
        return UpscaleResult(image: stitched, tileCount: plan.tiles.count)
    }

    private static func stitch(_ tiles: [(destOrigin: CGPoint, croppedOutput: UIImage)], canvasSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            for (origin, image) in tiles {
                image.draw(at: origin)
            }
        }
    }

    private func runModel(on tile: UIImage) async throws -> UIImage {
        guard let cgTile = tile.cgImage else { throw UpscaleError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            // VNImageRequestHandler.perform(_:) can itself throw the very
            // same error it already delivered to a request's completion
            // handler (Apple's documented behavior, not a bug on Vision's
            // end) — without this guard, a tile that fails partway through
            // inference resumes the continuation twice: once from the
            // completion handler below, once more from the `catch` at the
            // bottom. A second resume on an already-resumed
            // CheckedContinuation is a fatal "SWIFT TASK CONTINUATION
            // MISUSE" crash, not a recoverable error — this is the actual
            // shape of "some images crash the app while upscaling" bug
            // reports matched, since it only fires when a request fails
            // (more likely the longer/larger a photo's tile run is).
            let hasResumed = NSLock()
            var didResume = false
            func resumeOnce(_ result: Result<UIImage, Error>) {
                hasResumed.lock()
                let shouldResume = !didResume
                didResume = true
                hasResumed.unlock()
                guard shouldResume else { return }
                switch result {
                case .success(let image): continuation.resume(returning: image)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error {
                    resumeOnce(.failure(error))
                    return
                }
                guard let observation = request.results?.first as? VNPixelBufferObservation else {
                    resumeOnce(.failure(UpscaleError.noModelOutput))
                    return
                }
                let ciImage = CIImage(cvPixelBuffer: observation.pixelBuffer)
                guard let rendered = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                    resumeOnce(.failure(UpscaleError.renderFailed))
                    return
                }
                resumeOnce(.success(UIImage(cgImage: rendered, scale: 1, orientation: .up)))
            }
            // Every tile is already exactly the model's expected input size
            // (see ImageTiler), so this is a no-op in practice — set anyway
            // in case a future model config feeds non-square/odd-sized tiles.
            request.imageCropAndScaleOption = .scaleFill

            // VNImageRequestHandler.perform runs the model synchronously and
            // can take real time (CPU/GPU/ANE inference) — dispatch
            // explicitly to a background queue instead of blocking whatever
            // Swift Concurrency cooperative-pool thread happens to be
            // running this continuation's closure body.
            DispatchQueue.global(qos: .userInitiated).async {
                // perform() runs its completion handler (above — the
                // CIImage/CGImage conversion) synchronously within this same
                // call, so one autoreleasepool here covers both. Background
                // dispatch queue threads don't get an implicit per-iteration
                // drain the way the main run loop does, and a full-size
                // image can mean 30-50+ tiles through this exact path —
                // enough intermediate CGImage/CIImage/UIImage churn per
                // batch item that it matters, especially queued across a
                // multi-photo batch.
                autoreleasepool {
                    let handler = VNImageRequestHandler(cgImage: cgTile, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        resumeOnce(.failure(error))
                    }
                }
            }
        }
    }
}
