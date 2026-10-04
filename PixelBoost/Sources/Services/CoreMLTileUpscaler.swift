import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// Runs a bundled Core ML super-resolution model (e.g. a converted
/// Real-ESRGAN) over an image, tile by tile via `ImageTiler`, and stitches
/// the results back together. See Models/README.md for how to obtain/convert
/// a model and what `tileSize`/`scaleFactor` need to match it.
///
/// **Pixel by pixel.** Every source pixel goes through the model at its
/// original resolution — there is no pre-inference downscale any more (the
/// old Detail budget shrank anything over 4/8/16 MP before the model ever
/// saw it). The pipeline works on raw pixel memory end to end:
///
/// 1. The source is decoded once into a BGRA buffer in its own color space
///    (a Display P3 photo stays P3 — no silent gamut squeeze to sRGB).
/// 2. Each model input tile is copied straight out of that buffer into a
///    pooled `CVPixelBuffer`, with clamp-to-edge for the overlap margin past
///    the photo's border. No per-tile UIKit drawing.
/// 3. The model runs directly through `MLModel.predictions(from:)` in small
///    batches (Vision is only a fallback for models whose I/O isn't a plain
///    BGRA image).
/// 4. At native scale each tile's kept core is copied row by row into the
///    output canvas — the stitched result is bit-for-bit what the model
///    produced. At a non-native scale the tile is resampled into place.
/// 5. Transparency survives: the model sees un-premultiplied color, and the
///    source alpha is resampled and re-applied afterwards.
final class CoreMLTileUpscaler: ImageUpscaling {
    struct Config {
        /// Must match the model's fixed input width/height in pixels.
        var tileSize: Int = 128
        /// Must match the model's output-size-to-input-size ratio.
        var scaleFactor: Int = 4
        /// Context pixels fed to the model on each side of a tile beyond
        /// what's actually kept — improves quality right at tile borders.
        var overlap: Int = 8
        /// Fixed at load time — changing it means loading a new instance.
        var computeUnits: MLComputeUnits = .all
    }

    private let mlModel: MLModel
    private let visionModel: VNCoreMLModel
    private let modelName: String
    /// Set when the model takes exactly one `tileSize`² BGRA image and
    /// returns one image — the direct, Vision-free path.
    private let directIO: (input: String, output: String)?
    /// Flipped if the direct path ever fails at runtime, so the rest of the
    /// app's life uses the (slower, but proven) Vision path for this model.
    private var directPathFailed = false

    /// Mutable (not just at init) so `UpscalerProvider` can adjust overlap
    /// for a quality-preset change without re-loading the underlying
    /// `MLModel` — that load is the expensive part, not this struct.
    private(set) var config: Config
    var techniqueInfo: UpscaleTechniqueInfo {
        UpscaleTechniqueInfo(
            technique: "coreml_tile", modelName: modelName,
            tileSize: config.tileSize, overlap: config.overlap, scaleFactor: config.scaleFactor
        )
    }

    /// No color management: the models were trained on plain 0-255 values,
    /// and re-tagging their output against a working space shows up as a
    /// washed-out haze. Only used for unusual output pixel formats.
    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
    ])

    /// BGRA, premultiplied alpha first, little-endian: bytes in memory are
    /// B, G, R, A — the same layout as `kCVPixelFormatType_32BGRA`, so a
    /// row can move between a CVPixelBuffer and a CGContext with memcpy.
    private static let bgraBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(modelName: String = "RealESRGAN", config: Config = Config()) throws {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw UpscaleError.modelNotBundled(modelName)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = config.computeUnits
        let mlModel = try MLModel(contentsOf: url, configuration: configuration)
        self.mlModel = mlModel
        self.visionModel = try VNCoreMLModel(for: mlModel)
        self.modelName = modelName
        self.config = config
        self.directIO = Self.detectDirectIO(of: mlModel, tileSize: config.tileSize)
    }

    private static func detectDirectIO(of model: MLModel, tileSize: Int) -> (input: String, output: String)? {
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard inputs.count == 1, outputs.count == 1,
              let inputEntry = inputs.first, let outputEntry = outputs.first
        else { return nil }
        let inputName = inputEntry.key, input = inputEntry.value
        let outputName = outputEntry.key, output = outputEntry.value
        guard input.type == .image, output.type == .image,
              let constraint = input.imageConstraint,
              constraint.pixelsWide == tileSize, constraint.pixelsHigh == tileSize,
              constraint.pixelFormatType == kCVPixelFormatType_32BGRA
        else { return nil }
        return (inputName, outputName)
    }

    func updateOverlap(_ overlap: Int) {
        config.overlap = overlap
    }

    /// Largest final canvas this device can safely composite, in pixels.
    /// The canvas is 4 bytes/pixel and the post-passes that follow (blend,
    /// sharpen, watermark, export encode) each hold at least one more
    /// full-size copy, so this scales with physical RAM. It only ever
    /// limits the *output* size — the model still sees every source pixel.
    static let maxOutputPixels: Double = {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        switch gigabytes {
        case 7...: return 64_000_000
        case 5...: return 48_000_000
        default: return 32_000_000
        }
    }()

    /// Final canvas size for a request — exposed so the UI can show the
    /// exact output (and whether the memory cap kicked in) before running.
    static func outputSize(sourceWidth: Int, sourceHeight: Int, scale: Double) -> (width: Int, height: Int, capped: Bool) {
        let requested = Double(sourceWidth) * Double(sourceHeight) * scale * scale
        let cap = min(1, sqrt(maxOutputPixels / max(1, requested)))
        return (
            max(1, Int((Double(sourceWidth) * scale * cap).rounded())),
            max(1, Int((Double(sourceHeight) * scale * cap).rounded())),
            cap < 1
        )
    }

    func upscale(_ image: UIImage, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        try await upscale(image, outputScale: Double(config.scaleFactor), session: nil, progress: progress)
    }

    func upscale(_ image: UIImage, session: UpscaleSession?, progress: @escaping (Double) -> Void) async throws -> UpscaleResult {
        try await upscale(image, outputScale: Double(config.scaleFactor), session: session, progress: progress)
    }

    /// - Parameter outputScale: final size as a multiple of `image`'s own
    ///   dimensions — independent of the model's native `scaleFactor`.
    func upscale(
        _ image: UIImage,
        outputScale: Double,
        session: UpscaleSession?,
        progress: @escaping (Double) -> Void
    ) async throws -> UpscaleResult {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }
        let power = session?.power ?? UpscalePower.balanced.effective
        let tileSize = config.tileSize
        let nativeScale = config.scaleFactor

        // 1. Decode every source pixel once, in the photo's own color space.
        guard let source = PixelPlane(decoding: cgImage) else { throw UpscaleError.renderFailed }
        let colorSpace = source.colorSpace
        let alphaPlane = source.unpremultiplyIfTransparent()

        let output = Self.outputSize(sourceWidth: source.width, sourceHeight: source.height, scale: outputScale)
        guard let canvas = CGContext(
            data: nil, width: output.width, height: output.height, bitsPerComponent: 8,
            bytesPerRow: output.width * 4, space: colorSpace, bitmapInfo: Self.bgraBitmapInfo
        ), let canvasData = canvas.data else {
            throw UpscaleError.renderFailed
        }
        canvas.setAllowsAntialiasing(false)
        canvas.interpolationQuality = .high
        // CG draws bottom-left-origin; flip once so draw calls use the same
        // top-left coordinates as the tiler and the raw row copies.
        canvas.translateBy(x: 0, y: CGFloat(output.height))
        canvas.scaleBy(x: 1, y: -1)

        let scaleX = Double(output.width) / Double(source.width)
        let scaleY = Double(output.height) / Double(source.height)
        let isNativeScale = abs(scaleX - Double(nativeScale)) < 0.0001 && abs(scaleY - Double(nativeScale)) < 0.0001

        let tiler = ImageTiler(tileSize: tileSize, overlap: config.overlap, scaleFactor: nativeScale)
        let plan = tiler.plan(imageWidth: source.width, imageHeight: source.height)
        let core = tileSize - config.overlap * 2
        let columns = (source.width + core - 1) / core
        let rows = (source.height + core - 1) / core

        let preview = session?.onFrame == nil ? nil : LivePreview(outputWidth: output.width, outputHeight: output.height, colorSpace: colorSpace)
        guard let inputPool = Self.makePool(size: tileSize) else { throw UpscaleError.renderFailed }
        let queue = DispatchQueue(label: "pixelboost.tiles", qos: power.dispatchQoS)

        // Identical input tiles (flat backgrounds, letterbox bars, UI
        // chrome) skip the model: same input, same deterministic output.
        let tileCache = TileCache(capacity: 32)
        var tilesReused = 0

        var lastProgressAt = Date.distantPast
        var lastFrameAt = Date.distantPast
        var pixelsDone = 0
        let pixelsTotal = source.width * source.height

        var index = 0
        while index < plan.tiles.count {
            try Task.checkCancellation()
            try await session?.waitWhilePaused()

            let pacing = power.pacingDelay(for: ProcessInfo.processInfo.thermalState)
            if pacing > 0 {
                try await Task.sleep(nanoseconds: UInt64(pacing * 1_000_000_000))
            }

            let batch = Array(plan.tiles[index..<min(index + power.batchSize, plan.tiles.count)])
            let inputs = try batch.map { tile -> CVPixelBuffer in
                guard let buffer = Self.pooledBuffer(inputPool) else { throw UpscaleError.renderFailed }
                source.copyTile(origin: (Int(tile.sourceRect.minX), Int(tile.sourceRect.minY)), size: tileSize, into: buffer)
                return buffer
            }
            var resolved = [CVPixelBuffer?](repeating: nil, count: inputs.count)
            var misses: [(index: Int, input: CVPixelBuffer, key: UInt64)] = []
            for (i, input) in inputs.enumerated() {
                let key = TileCache.hash(input)
                if let hit = tileCache.output(for: key, matching: input) {
                    resolved[i] = hit
                    tilesReused += 1
                } else {
                    misses.append((i, input, key))
                }
            }
            if !misses.isEmpty {
                let predicted = try await predict(misses.map { $0.input }, on: queue)
                for (miss, output) in zip(misses, predicted) {
                    resolved[miss.index] = output
                    tileCache.store(output, for: miss.key, input: miss.input)
                }
            }
            let outputs = resolved.compactMap { $0 }
            guard outputs.count == inputs.count else { throw UpscaleError.noModelOutput }

            for (tile, outputBuffer) in zip(batch, outputs) {
                let coreX = Int(tile.sourceRect.minX + tile.keepRect.minX)
                let coreY = Int(tile.sourceRect.minY + tile.keepRect.minY)
                let coreW = Int(tile.keepRect.width)
                let coreH = Int(tile.keepRect.height)
                let keepDest = CGRect(
                    x: (Double(coreX) * scaleX).rounded(),
                    y: (Double(coreY) * scaleY).rounded(),
                    width: (Double(coreX + coreW) * scaleX).rounded() - (Double(coreX) * scaleX).rounded(),
                    height: (Double(coreY + coreH) * scaleY).rounded() - (Double(coreY) * scaleY).rounded()
                )

                let tileImage: CGImage? = autoreleasepool {
                    let bgra = Self.bgraView(of: outputBuffer)
                    defer { bgra.release() }
                    let outW = bgra.width, outH = bgra.height
                    if isNativeScale, outW == tileSize * nativeScale, outH == tileSize * nativeScale {
                        // Pixel-exact: copy the model's kept rows verbatim.
                        let rowBytes = coreW * nativeScale * 4
                        let srcX = Int(tile.keepRect.minX) * nativeScale
                        let srcY = Int(tile.keepRect.minY) * nativeScale
                        let dstX = coreX * nativeScale
                        let dstY = coreY * nativeScale
                        for row in 0..<(coreH * nativeScale) {
                            let from = bgra.base + (srcY + row) * bgra.bytesPerRow + srcX * 4
                            let to = canvasData + (dstY + row) * canvas.bytesPerRow + dstX * 4
                            memcpy(to, from, rowBytes)
                        }
                        return preview == nil ? nil : bgra.makeImage(colorSpace: colorSpace)
                    }
                    // Non-native scale: draw the whole tile (context
                    // included) scaled into place, clipped to its core, so
                    // the resampler filters from real neighbors.
                    guard let image = bgra.makeImage(colorSpace: colorSpace) else { return nil }
                    let tileDest = CGRect(
                        x: Double(tile.sourceRect.minX) * scaleX,
                        y: Double(tile.sourceRect.minY) * scaleY,
                        width: Double(tile.sourceRect.width) * scaleX,
                        height: Double(tile.sourceRect.height) * scaleY
                    )
                    canvas.saveGState()
                    canvas.clip(to: keepDest)
                    // CGContext.draw puts the image upright in a y-up space;
                    // undo the canvas flip locally for this one call.
                    canvas.translateBy(x: 0, y: tileDest.maxY)
                    canvas.scaleBy(x: 1, y: -1)
                    canvas.draw(image, in: CGRect(x: tileDest.minX, y: 0, width: tileDest.width, height: tileDest.height))
                    canvas.restoreGState()
                    return image
                }

                if let preview, let tileImage {
                    let keepInTile = CGRect(
                        x: tile.keepRect.minX * CGFloat(tileImage.width) / CGFloat(tileSize),
                        y: tile.keepRect.minY * CGFloat(tileImage.height) / CGFloat(tileSize),
                        width: tile.keepRect.width * CGFloat(tileImage.width) / CGFloat(tileSize),
                        height: tile.keepRect.height * CGFloat(tileImage.height) / CGFloat(tileSize)
                    )
                    if let coreImage = tileImage.cropping(to: keepInTile) {
                        preview.draw(coreImage, at: keepDest)
                    }
                }
                pixelsDone += coreW * coreH
            }

            index += batch.count
            let fraction = Double(index) / Double(plan.tiles.count)
            let now = Date()
            // Throttled: a 12 MP photo is ~1,000 tiles, and every callback
            // becomes a main-thread SwiftUI update.
            if index == plan.tiles.count || now.timeIntervalSince(lastProgressAt) > 0.2 {
                lastProgressAt = now
                progress(fraction)
            }
            if let session, let onFrame = session.onFrame,
               index == plan.tiles.count || now.timeIntervalSince(lastFrameAt) > power.previewInterval {
                lastFrameAt = now
                let first = batch[0].sourceRect, last = batch[batch.count - 1].sourceRect
                let active = first.union(last).insetBy(dx: CGFloat(config.overlap), dy: CGFloat(config.overlap))
                onFrame(UpscaleLiveFrame(
                    preview: preview?.snapshot(),
                    tilesDone: index, tilesTotal: plan.tiles.count,
                    columns: columns, rows: rows,
                    activeRegion: CGRect(
                        x: active.minX / CGFloat(source.width), y: active.minY / CGFloat(source.height),
                        width: active.width / CGFloat(source.width), height: active.height / CGFloat(source.height)
                    ),
                    tilesReused: tilesReused,
                    pixelsDone: pixelsDone, pixelsTotal: pixelsTotal,
                    isThermalPaced: pacing > 0
                ))
            }
        }

        // 5. Hold the result to the source's real pixels (Detail Lock +
        //    Halo Guard) while the canvas is still opaque.
        var fidelityPSNR: Double?
        if let fidelity = session?.fidelity, fidelity != .off, outputScale > 1 {
            try Task.checkCancellation()
            fidelityPSNR = FidelityRefiner.refine(
                canvas: canvasData, width: output.width, height: output.height, bytesPerRow: canvas.bytesPerRow,
                source: source.data, sourceWidth: source.width, sourceHeight: source.height, sourceBytesPerRow: source.bytesPerRow,
                fidelity: fidelity
            )
        }

        // 6. Put the photo's own transparency back over the opaque model output.
        if let alphaPlane {
            Self.applyAlpha(alphaPlane, sourceWidth: source.width, sourceHeight: source.height, to: canvasData, width: output.width, height: output.height, bytesPerRow: canvas.bytesPerRow)
        }

        guard let stitched = canvas.makeImage() else { throw UpscaleError.renderFailed }
        return UpscaleResult(
            image: UIImage(cgImage: stitched, scale: 1, orientation: .up),
            tileCount: plan.tiles.count,
            modelInputSize: CGSize(width: source.width, height: source.height),
            outputWasCapped: output.capped,
            fidelityPSNR: fidelityPSNR,
            tilesReused: tilesReused
        )
    }

    // MARK: - Inference

    private func predict(_ inputs: [CVPixelBuffer], on queue: DispatchQueue) async throws -> [CVPixelBuffer] {
        if let directIO, !directPathFailed {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    queue.async { [mlModel] in
                        autoreleasepool {
                            do {
                                let providers: [MLFeatureProvider] = try inputs.map {
                                    try MLDictionaryFeatureProvider(dictionary: [directIO.input: MLFeatureValue(pixelBuffer: $0)])
                                }
                                let results = try mlModel.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions())
                                var buffers: [CVPixelBuffer] = []
                                for i in 0..<results.count {
                                    guard let buffer = results.features(at: i).featureValue(for: directIO.output)?.imageBufferValue else {
                                        throw UpscaleError.noModelOutput
                                    }
                                    buffers.append(buffer)
                                }
                                continuation.resume(returning: buffers)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            } catch {
                // Fall through to Vision for this and every later batch.
                directPathFailed = true
            }
        }
        var outputs: [CVPixelBuffer] = []
        for input in inputs {
            outputs.append(try await runVision(on: input, queue: queue))
        }
        return outputs
    }

    private func runVision(on input: CVPixelBuffer, queue: DispatchQueue) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { continuation in
            // VNImageRequestHandler.perform(_:) can throw the same error it
            // already delivered to the completion handler — guard against
            // resuming the continuation twice (a fatal misuse crash).
            let lock = NSLock()
            var didResume = false
            func resumeOnce(_ result: Result<CVPixelBuffer, Error>) {
                lock.lock()
                let shouldResume = !didResume
                didResume = true
                lock.unlock()
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error { resumeOnce(.failure(error)); return }
                guard let observation = request.results?.first as? VNPixelBufferObservation else {
                    resumeOnce(.failure(UpscaleError.noModelOutput))
                    return
                }
                resumeOnce(.success(observation.pixelBuffer))
            }
            request.imageCropAndScaleOption = .scaleFill

            queue.async {
                autoreleasepool {
                    let handler = VNImageRequestHandler(cvPixelBuffer: input, options: [:])
                    do { try handler.perform([request]) } catch { resumeOnce(.failure(error)) }
                }
            }
        }
    }

    // MARK: - Pixel buffers

    private static func makePool(size: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size,
            kCVPixelBufferHeightKey: size,
            // IOSurface-backed so the Neural Engine/GPU can read the tile
            // without another copy.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private static func pooledBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// A locked, BGRA-ordered read view of a model output buffer. 32BGRA
    /// outputs (the norm) are read in place; anything else is converted
    /// once into a scratch BGRA buffer.
    private struct BGRAView {
        let base: UnsafeMutableRawPointer
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let release: () -> Void

        func makeImage(colorSpace: CGColorSpace) -> CGImage? {
            CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CoreMLTileUpscaler.bgraBitmapInfo
            )?.makeImage()
        }
    }

    private static func bgraView(of buffer: CVPixelBuffer) -> BGRAView {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                return BGRAView(
                    base: base, width: width, height: height,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    release: { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let bytesPerRow = width * 4
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytesPerRow * height), alignment: 16)
        ciContext.render(
            CIImage(cvPixelBuffer: buffer), toBitmap: scratch, rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .BGRA8, colorSpace: nil
        )
        return BGRAView(base: scratch, width: width, height: height, bytesPerRow: bytesPerRow, release: { scratch.deallocate() })
    }

    /// Resamples the source's alpha plane to the canvas size and
    /// premultiplies the (opaque) model output by it.
    private static func applyAlpha(_ alpha: Data, sourceWidth: Int, sourceHeight: Int, to canvas: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: alpha as CFData),
              let alphaImage = CGImage(
                width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: sourceWidth, space: gray,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ),
              let mask = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return }
        mask.interpolationQuality = .high
        mask.draw(alphaImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let maskData = mask.data else { return }
        for y in 0..<height {
            let alphaRow = maskData.advanced(by: y * mask.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let pixelRow = canvas.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let a = UInt16(alphaRow[x])
                if a == 255 { continue }
                let p = pixelRow + x * 4
                p[0] = UInt8((UInt16(p[0]) * a + 127) / 255)
                p[1] = UInt8((UInt16(p[1]) * a + 127) / 255)
                p[2] = UInt8((UInt16(p[2]) * a + 127) / 255)
                p[3] = UInt8(a)
            }
        }
    }
}

/// Recently seen model inputs and their outputs, keyed by a content hash
/// and confirmed byte-for-byte before reuse.
private final class TileCache {
    private let capacity: Int
    private var entries: [UInt64: (input: Data, output: CVPixelBuffer)] = [:]
    private var order: [UInt64] = []

    init(capacity: Int) { self.capacity = capacity }

    /// FNV-1a over each row's pixel bytes (row padding excluded, so two
    /// identical tiles always hash alike).
    static func hash(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let wordsPerRow = CVPixelBufferGetWidth(buffer) * 4 / 8
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let words = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt64.self)
            for i in 0..<wordsPerRow {
                h = (h ^ words[i]) &* 0x0000_0100_0000_01b3
            }
        }
        return h
    }

    private static func bytes(of buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let payload = CVPixelBufferGetWidth(buffer) * 4
        var data = Data(capacity: payload * CVPixelBufferGetHeight(buffer))
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: payload)
        }
        return data
    }

    func output(for key: UInt64, matching input: CVPixelBuffer) -> CVPixelBuffer? {
        guard let entry = entries[key], entry.input == Self.bytes(of: input) else { return nil }
        return entry.output
    }

    func store(_ output: CVPixelBuffer, for key: UInt64, input: CVPixelBuffer) {
        guard entries[key] == nil else { return }
        if order.count >= capacity {
            entries[order.removeFirst()] = nil
        }
        entries[key] = (Self.bytes(of: input), output)
        order.append(key)
    }
}

/// The decoded source photo as raw BGRA memory — what every model input
/// tile is copied out of.
private final class PixelPlane {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let colorSpace: CGColorSpace
    private let context: CGContext
    let data: UnsafeMutableRawPointer

    init?(decoding image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let preferred = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: image.width * 4, space: space, bitmapInfo: bitmapInfo)
        }
        guard let context = makeContext(preferred) ?? makeContext(sRGB), let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.context = context
        self.data = data
        self.colorSpace = context.colorSpace ?? sRGB
    }

    /// Un-premultiplies in place if any pixel is less than fully opaque,
    /// so the model sees true color at soft edges instead of color darkened
    /// toward black, then marks every pixel opaque for the model. Returns
    /// the original alpha plane (one byte per pixel, row-major), or nil if
    /// the photo has no transparency at all.
    func unpremultiplyIfTransparent() -> Data? {
        var transparent = false
        for y in 0..<height where !transparent {
            let row = data.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where row[x * 4 + 3] != 255 {
                transparent = true
                break
            }
        }
        guard transparent else { return nil }
        var alpha = Data(count: width * height)
        alpha.withUnsafeMutableBytes { buffer in
            guard let plane = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let row = data.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let p = row + x * 4
                    let a = UInt16(p[3])
                    plane[y * width + x] = p[3]
                    if a != 255 && a != 0 {
                        p[0] = UInt8(min(255, (UInt16(p[0]) * 255 + a / 2) / a))
                        p[1] = UInt8(min(255, (UInt16(p[1]) * 255 + a / 2) / a))
                        p[2] = UInt8(min(255, (UInt16(p[2]) * 255 + a / 2) / a))
                    }
                    p[3] = 255
                }
            }
        }
        return alpha
    }

    /// Copies a `size`² square whose top-left is `origin` (which may lie
    /// outside the photo) into `buffer`. Pixels past the border repeat the
    /// nearest edge pixel — clamp-to-edge — so a CNN tile at the frame
    /// edge sees plausible context rather than a hard blank boundary.
    func copyTile(origin: (x: Int, y: Int), size: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let midStart = max(origin.x, 0)
        let midEnd = min(origin.x + size, width)
        let midCount = max(0, midEnd - midStart)
        let leftCount = min(size, max(0, -origin.x))

        for row in 0..<size {
            let sourceY = min(max(origin.y + row, 0), height - 1)
            let sourceRow = data.advanced(by: sourceY * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            let destinationRow = destination.advanced(by: row * destinationBytesPerRow).assumingMemoryBound(to: UInt32.self)
            if midCount > 0 {
                if leftCount > 0 {
                    destinationRow.update(repeating: sourceRow[0], count: leftCount)
                }
                (destinationRow + leftCount).update(from: sourceRow + midStart, count: midCount)
                let rightCount = size - leftCount - midCount
                if rightCount > 0 {
                    (destinationRow + leftCount + midCount).update(repeating: sourceRow[width - 1], count: rightCount)
                }
            } else {
                for column in 0..<size {
                    destinationRow[column] = sourceRow[min(max(origin.x + column, 0), width - 1)]
                }
            }
        }
    }
}

/// A small running copy of the output canvas for the live "watch it fill
/// in" view — finished tiles are drawn in at preview resolution as they
/// complete, so showing progress never touches the full-size canvas.
private final class LivePreview {
    private let context: CGContext
    private let scale: CGFloat
    private let height: Int

    init?(outputWidth: Int, outputHeight: Int, colorSpace: CGColorSpace) {
        let maxSide: CGFloat = 900
        let scale = min(1, maxSide / CGFloat(max(outputWidth, outputHeight)))
        let width = max(1, Int((CGFloat(outputWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(outputHeight) * scale).rounded()))
        self.scale = scale
        self.height = height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        self.context = context
    }

    /// `rect` is in output-canvas pixels, top-left origin.
    func draw(_ image: CGImage, at rect: CGRect) {
        let target = CGRect(
            x: rect.minX * scale,
            y: CGFloat(height) - rect.maxY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        context.draw(image, in: target)
    }

    func snapshot() -> CGImage? { context.makeImage() }
}
