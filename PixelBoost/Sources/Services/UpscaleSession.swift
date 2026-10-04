import CoreGraphics
import CoreML
import Foundation

/// How hard an upscale is allowed to push the phone. This is no longer a
/// resolution dial — every upscale now runs every source pixel through the
/// model (see `CoreMLTileUpscaler`) — it only decides *where* and *how fast*
/// that work happens, which is what actually moves battery drain and heat:
///
/// - **Efficiency** keeps inference on the Neural Engine + CPU (no GPU, the
///   most power-hungry of the three for these convolution-heavy models),
///   runs the tile loop at utility QoS so the scheduler can keep it on
///   efficiency cores, and paces itself as soon as the phone gets warm.
/// - **Balanced** lets Core ML pick any compute unit and only backs off
///   once the device reports serious thermal pressure.
/// - **Performance** batches more tiles per prediction call and only backs
///   off at critical thermal state.
///
/// Low Power Mode quietly downgrades Balanced/Performance to Efficiency
/// (see `effective`) — someone who turned it on has already told us what
/// they want.
enum UpscalePower: String, CaseIterable, Identifiable {
    case efficiency
    case balanced
    case performance

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .efficiency: return "Efficiency"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        }
    }

    var systemImage: String {
        switch self {
        case .efficiency: return "leaf"
        case .balanced: return "gauge.with.dots.needle.50percent"
        case .performance: return "bolt"
        }
    }

    var footnote: String {
        switch self {
        case .efficiency: return "Neural Engine only, paced to stay cool. Slowest, lightest on battery."
        case .balanced: return "Any compute unit; eases off when the phone gets hot."
        case .performance: return "Bigger batches, backs off only at critical heat. Fastest, warmest."
        }
    }

    /// What actually runs, after Low Power Mode is taken into account.
    var effective: UpscalePower {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .efficiency : self
    }

    var computeUnits: MLComputeUnits {
        self == .efficiency ? .cpuAndNeuralEngine : .all
    }

    /// Tiles handed to one `MLModel.predictions(from:)` call. Larger
    /// batches let Core ML keep the accelerator fed between tiles.
    var batchSize: Int {
        switch self {
        case .efficiency: return 2
        case .balanced: return 4
        case .performance: return 8
        }
    }

    var dispatchQoS: DispatchQoS {
        self == .efficiency ? .utility : .userInitiated
    }

    /// Pause inserted between batches at the current thermal state.
    func pacingDelay(for state: ProcessInfo.ThermalState) -> TimeInterval {
        switch (self, state) {
        case (_, .critical): return 1.5
        case (.efficiency, .serious): return 0.5
        case (.balanced, .serious): return 0.25
        case (.efficiency, .fair): return 0.05
        default: return 0
        }
    }

    /// Minimum gap between live-preview frames — each frame is a small
    /// image copy plus a SwiftUI redraw, so the cheaper mode draws less.
    var previewInterval: TimeInterval {
        self == .efficiency ? 0.8 : 0.35
    }
}

/// One live-preview update from a running upscale.
struct UpscaleLiveFrame {
    /// The output canvas so far, downsampled to preview size — finished
    /// tiles show real model output, the rest is still empty.
    let preview: CGImage?
    let tilesDone: Int
    let tilesTotal: Int
    let columns: Int
    let rows: Int
    /// The batch being processed right now, normalized to 0...1 of the
    /// output frame (top-left origin).
    let activeRegion: CGRect
    /// Tiles whose input exactly matched an earlier tile, so the earlier
    /// output was reused instead of running the model again.
    let tilesReused: Int
    /// Source pixels already through the model.
    let pixelsDone: Int
    let pixelsTotal: Int
    let isThermalPaced: Bool
}

/// Run-scoped controls for one upscale: pause/resume, which power mode it
/// runs under, and an optional live feed. Cancellation stays ordinary
/// Swift task cancellation; this only adds what tasks can't express.
final class UpscaleSession: @unchecked Sendable {
    let power: UpscalePower
    /// Post-model refinement against the source pixels — see `UpscaleFidelity`.
    let fidelity: UpscaleFidelity
    /// Called from a background thread, throttled to `power.previewInterval`.
    let onFrame: ((UpscaleLiveFrame) -> Void)?

    private let lock = NSLock()
    private var paused = false

    init(power: UpscalePower, fidelity: UpscaleFidelity = .off, onFrame: ((UpscaleLiveFrame) -> Void)? = nil) {
        self.power = power.effective
        self.fidelity = fidelity
        self.onFrame = onFrame
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; lock.unlock()
    }

    /// Parks the tile loop between batches while paused. Polls slowly —
    /// a paused upscale should cost close to nothing.
    func waitWhilePaused() async throws {
        while isPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}

/// What an upscale will do before it runs: exact output size, tile count,
/// and a time estimate learned from this device's own previous runs.
struct UpscalePlan {
    let outputWidth: Int
    let outputHeight: Int
    let outputWasCapped: Bool
    let tiles: Int
    let sourcePixels: Int
    let estimatedSeconds: Double?

    var outputMegapixels: Double { Double(outputWidth * outputHeight) / 1_000_000 }
}

/// Learns seconds-per-tile per model and power mode from finished runs
/// (an exponential moving average in UserDefaults — a few bytes, no
/// network), so the ETA reflects this particular phone.
enum UpscaleEstimator {
    private static let defaultsPrefix = "com.pixelboost.secondsPerTile."

    private static func key(model: String, power: UpscalePower) -> String {
        defaultsPrefix + model + "." + power.rawValue
    }

    static func plan(sourceWidth: Int, sourceHeight: Int, scale: Int, overlap: Int?, model: String?, power: UpscalePower) -> UpscalePlan {
        let output = CoreMLTileUpscaler.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight, scale: Double(scale))
        guard let overlap, let model else {
            return UpscalePlan(
                outputWidth: output.width, outputHeight: output.height, outputWasCapped: output.capped,
                tiles: 0, sourcePixels: sourceWidth * sourceHeight, estimatedSeconds: 1
            )
        }
        let core = max(1, 128 - overlap * 2)
        let tiles = ((sourceWidth + core - 1) / core) * ((sourceHeight + core - 1) / core)
        let perTile = UserDefaults.standard.object(forKey: key(model: model, power: power.effective)) as? Double
        return UpscalePlan(
            outputWidth: output.width, outputHeight: output.height, outputWasCapped: output.capped,
            tiles: tiles, sourcePixels: sourceWidth * sourceHeight,
            estimatedSeconds: perTile.map { $0 * Double(tiles) }
        )
    }

    static func record(model: String?, power: UpscalePower, tiles: Int?, seconds: TimeInterval) {
        guard let model, let tiles, tiles > 0, seconds > 0 else { return }
        let sample = seconds / Double(tiles)
        let key = key(model: model, power: power.effective)
        let previous = UserDefaults.standard.object(forKey: key) as? Double
        UserDefaults.standard.set(previous.map { $0 * 0.7 + sample * 0.3 } ?? sample, forKey: key)
    }

    static func format(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(1, s))s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
