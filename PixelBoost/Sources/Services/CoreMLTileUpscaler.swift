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
        // .cpuAndGPU, not the .all default. Diagnosis, not yet confirmed on
        // real hardware (see Models/README.md): these conversions were
        // never runtime-validated before shipping, and exported images
        // reportedly come out torn into repeating horizontal bands on some
        // runs and correct on others, same model/input, with nothing
        // random anywhere in ImageTiler or this file's own compositing —
        // that non-determinism points at the runtime, not this code. This
        // exact architecture shape (RRDBNet's dense-block concatenations +
        // F.interpolate-based nearest-neighbor upsampling, run once per
        // 128x128 tile) matches a known class of Core ML bug where the
        // Neural Engine miscompiles part of a graph like this while
        // CPU/GPU execution of the identical graph is correct. Forcing
        // .cpuAndGPU rules the ANE out; if the corruption persists after
        // this change, the cause is elsewhere and this should be reverted
        // (it costs real speed with no upside otherwise).
        let modelConfig = MLModelConfiguration()
        modelConfig.computeUnits = .cpuAndGPU
        let mlModel = try MLModel(contentsOf: url, configuration: modelConfig)
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

        // Tiles are drawn straight into one shared bitmap context as each
        // one finishes, instead of collecting every tile's cropped output
        // in an array and stitching them all at the very end. A large
        // photo can mean many dozens of tiles, each holding a full
        // scaleFactor-sized UIImage/CGImage — retaining all of them
        // simultaneously alongside the final full-size canvas roughly
        // doubled peak memory right when it was already highest, which is
        // exactly the shape of crash a long/large upscale would hit (see
        // README's "no disk-based caching of intermediate tiles" known
        // simplification — this doesn't remove that limitation, but it
        // does stop needlessly holding two copies of the same data at once).
        //
        // A real `CGContext`, not `UIGraphicsBeginImageContextWithOptions`
        // — that legacy API's "current context" lives on a per-thread
        // stack, but Swift Concurrency doesn't guarantee this loop resumes
        // on the same OS thread after each `await runModel(...)` below, so
        // a later tile's draw could silently miss the context entirely (or
        // land on the wrong thread's stack). A `CGContext` is just an
        // object — holding a reference to it across suspension points and
        // calling `draw` on it directly is thread-independent.
        let outputWidth = Int(plan.outputSize.width)
        let outputHeight = Int(plan.outputSize.height)
        guard let canvas = CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw UpscaleError.renderFailed }
        // CGContext's native origin is bottom-left with y pointing up;
        // every tile's `destOrigin`/`keepRect` (from `ImageTiler`) is in
        // the top-left/y-down convention the rest of this codebase uses
        // (matching `UIImage.draw`/`UIGraphicsImageRenderer`). Flipping
        // once up front means every tile below can use its destOrigin
        // as-is instead of each draw call re-deriving a flipped rect.
        canvas.translateBy(x: 0, y: CGFloat(outputHeight))
        canvas.scaleBy(x: 1, y: -1)

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
            guard let croppedCGImage = croppedOutput.cgImage else { throw UpscaleError.renderFailed }
            canvas.draw(
                croppedCGImage,
                in: CGRect(origin: tile.destOrigin, size: CGSize(width: croppedCGImage.width, height: croppedCGImage.height))
            )
            progress(Double(index + 1) / Double(plan.tiles.count))
        }

        guard let outputCGImage = canvas.makeImage() else { throw UpscaleError.renderFailed }
        let stitched = UIImage(cgImage: outputCGImage, scale: 1, orientation: .up)
        return UpscaleResult(image: stitched, tileCount: plan.tiles.count)
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
