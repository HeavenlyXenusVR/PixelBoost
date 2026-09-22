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

    /// Largest final canvas this device can safely composite, in pixels.
    /// The canvas itself is 4 bytes/pixel, and the post-passes that follow
    /// (blend, sharpen, watermark, export encode) each hold at least one
    /// more full-size copy, so this scales with physical RAM rather than
    /// being one number for every iPhone — 32MP was the old single budget,
    /// which was fine on 4GB devices but needlessly tight on 8GB ones.
    static let maxOutputPixels: Double = {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        switch gigabytes {
        case 7...: return 64_000_000
        case 5...: return 48_000_000
        default: return 32_000_000
        }
    }()

    /// Model input budget used by `upscale(_:progress:)` — the path Render
    /// Denoise and the Shortcuts intent take, neither of which has a
    /// user-facing Detail setting.
    static let defaultMaxModelInputPixels: Double = 16_000_000

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        try await upscale(
            image, outputScale: Double(config.scaleFactor),
            maxModelInputPixels: Self.defaultMaxModelInputPixels, progress: progress
        )
    }

    /// - Parameter outputScale: final size as a multiple of `image`'s own
    ///   dimensions — independent of the model's native `scaleFactor`.
    ///   Each tile's native-scale model output is resampled straight into
    ///   a canvas of this size, so a 2x target never allocates (or
    ///   stretches back up from) a 4x-sized intermediate.
    /// - Parameter maxModelInputPixels: how many source pixels the model
    ///   actually gets to see. Larger inputs are downscaled *before*
    ///   inference only to this budget — this is the speed/heat vs. detail
    ///   dial (see `UpscaleDetail`). Detail the model never sees can't be
    ///   recovered by it, so this must never be derived from the *output*
    ///   budget: that was the v3.26.13–v3.26.17 bug, where a 12MP photo was
    ///   shrunk to ~1MP to fit a 16MP output cap before the model ran.
    func upscale(
        _ image: UIImage,
        outputScale: Double,
        maxModelInputPixels: Double,
        progress: @escaping (Double) -> Void
    ) async throws -> UpscaleResult {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }

        // Normalize once so every tile crop is a plain 1-point-per-pixel,
        // upright image — see UIImage+Tile.swift for why this matters.
        let normalized = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        let sourceWidth = Double(cgImage.width)
        let sourceHeight = Double(cgImage.height)
        let sourcePixels = sourceWidth * sourceHeight

        // Final output size: the requested scale, shrunk only if the canvas
        // itself wouldn't fit in memory (a 4x of a 15k-wide ultrawide keyart
        // is hundreds of megapixels). This cap only ever reduces the output
        // size — it never reduces what the model sees.
        let requestedOutputPixels = sourcePixels * outputScale * outputScale
        let outputCap = min(1, sqrt(Self.maxOutputPixels / max(1, requestedOutputPixels)))
        let canvasWidth = max(1, Int((sourceWidth * outputScale * outputCap).rounded()))
        let canvasHeight = max(1, Int((sourceHeight * outputScale * outputCap).rounded()))

        // Model input: full resolution unless it exceeds the detail budget.
        let workingImage: UIImage
        if sourcePixels > maxModelInputPixels {
            let scale = sqrt(maxModelInputPixels / sourcePixels)
            let targetSize = CGSize(
                width: max(1, (sourceWidth * scale).rounded()),
                height: max(1, (sourceHeight * scale).rounded())
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            workingImage = renderer.image { context in
                context.cgContext.interpolationQuality = .high
                normalized.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        } else {
            workingImage = normalized
        }

        guard let workingCGImage = workingImage.cgImage else { throw UpscaleError.invalidImage }
        // Tile size must stay `config.tileSize`: it's the model's fixed,
        // compiled input shape. (v3.26.17's area-adaptive 64/96px tiles
        // would have been stretched to 128 by Vision's .scaleFill and then
        // cropped with 64px-tile math — garbage output — had the input
        // ever been large enough to trigger them.)
        let tiler = ImageTiler(tileSize: config.tileSize, overlap: config.overlap, scaleFactor: config.scaleFactor)
        let plan = tiler.plan(imageWidth: workingCGImage.width, imageHeight: workingCGImage.height)

        // Working-image pixel -> canvas pixel. Separate x/y factors so the
        // last row/column lands exactly on the canvas edge after rounding.
        let scaleX = Double(canvasWidth) / Double(workingCGImage.width)
        let scaleY = Double(canvasHeight) / Double(workingCGImage.height)
        let isNativeScale = abs(scaleX - Double(config.scaleFactor)) < 0.0001
            && abs(scaleY - Double(config.scaleFactor)) < 0.0001

        // Keep a single canvas alive instead of storing every tile result in
        // memory until the end. Large/wide source photos can produce dozens of
        // tiles; holding all of them simultaneously is what makes this crash on
        // big inputs. Drawing each tile directly into the final output keeps the
        // working set bounded by the current tile plus the final canvas, rather
        // than O(plan.tiles) full-frame images.
        let bytesPerPixel = 4
        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw UpscaleError.renderFailed
        }
        context.setAllowsAntialiasing(false)
        context.interpolationQuality = isNativeScale ? .none : .high
        // A raw CGContext is initialized with the Core Graphics default of
        // origin-at-lower-left, while the tiler and image-crop math in this
        // code base use ordinary UIKit/top-left y-down coordinates. Flip the
        // canvas once before stitching so each tile lands in the correct place
        // instead of appearing as a second, upside-down layer.
        context.translateBy(x: 0, y: CGFloat(canvasHeight))
        context.scaleBy(x: 1, y: -1)

        for (index, tile) in plan.tiles.enumerated() {
            try Task.checkCancellation()
            // Edge-replicated, not a plain `cropped(to:)` — a tile
            // touching the photo's outer border needs its `overlap`-pixel
            // margin to be real (if flat) context, not a hard transparent
            // edge; see `croppedEdgeReplicated(to:)`'s doc comment for the
            // measured dark/smudged-fringe defect this fixes.
            let inputTile = workingImage.croppedEdgeReplicated(to: tile.sourceRect)
            let outputTile = try await runModel(on: inputTile)

            // The whole model output tile (overlap context included) is
            // drawn scaled into place and clipped to this tile's core
            // region, so resampling at a non-native scale still has real
            // neighboring pixels to filter from rather than a hard crop
            // edge. Core edges are rounded once, from the same formula for
            // both neighbors, so adjacent tiles abut with no gap/overlap.
            let coreMinX = Double(tile.sourceRect.minX + tile.keepRect.minX)
            let coreMinY = Double(tile.sourceRect.minY + tile.keepRect.minY)
            let keepDest = CGRect(
                x: (coreMinX * scaleX).rounded(),
                y: (coreMinY * scaleY).rounded(),
                width: ((coreMinX + Double(tile.keepRect.width)) * scaleX).rounded() - (coreMinX * scaleX).rounded(),
                height: ((coreMinY + Double(tile.keepRect.height)) * scaleY).rounded() - (coreMinY * scaleY).rounded()
            )
            let tileDest = CGRect(
                x: Double(tile.sourceRect.minX) * scaleX,
                y: Double(tile.sourceRect.minY) * scaleY,
                width: Double(tile.sourceRect.width) * scaleX,
                height: Double(tile.sourceRect.height) * scaleY
            )

            autoreleasepool {
                UIGraphicsPushContext(context)
                context.saveGState()
                context.clip(to: keepDest)
                outputTile.draw(in: tileDest)
                context.restoreGState()
                UIGraphicsPopContext()
            }
            progress(Double(index + 1) / Double(plan.tiles.count))
        }

        guard let stitchedCGImage = context.makeImage() else { throw UpscaleError.renderFailed }
        return UpscaleResult(image: UIImage(cgImage: stitchedCGImage, scale: 1, orientation: .up), tileCount: plan.tiles.count)
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
