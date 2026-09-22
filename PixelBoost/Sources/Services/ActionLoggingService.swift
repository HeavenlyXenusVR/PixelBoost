import Foundation
import UIKit

/// Records `ActionLogEntry` records for anything that isn't a full upscale
/// attempt — the general-purpose counterpart to `UpscaleLoggingService`.
///
/// Since 3.27.0 this is a thin front end over `TelemetryService`, which
/// buffers events and flushes them in batches (`POST /log/actions`), tags
/// each with the session id and current thermal state, and honors the
/// Diagnostics switch in Settings. The `log(_:detail:)` shape is kept
/// as-is so existing call sites don't all have to change; `outcome`/
/// `durationMS` are optional additions that land in their own columns
/// instead of being buried in `detail` JSON.
///
/// Fire-and-forget by design: a logging failure must never surface to the
/// user or block the action it's describing.
enum ActionLoggingService {
    /// - Parameter detail: encoded as a JSON object string server-side;
    ///   values should be JSON-serializable (`String`, `Bool`, `Int`,
    ///   `Double`, or `nil`).
    static func log(
        _ action: String,
        detail: [String: Any?] = [:],
        outcome: String? = nil,
        durationMS: Int? = nil
    ) {
        TelemetryService.record(action, detail: detail, outcome: outcome, durationMS: durationMS)
    }

    /// Convenience for the very common "this tool ran and either worked or
    /// threw" shape, so each call site doesn't re-spell it.
    static func logResult(
        _ action: String,
        error: Error?,
        detail: [String: Any?] = [:],
        durationMS: Int? = nil
    ) {
        var merged = detail
        if let error { merged["error"] = error.localizedDescription }
        log(action, detail: merged, outcome: error == nil ? "success" : "failed", durationMS: durationMS)
    }

    /// Times `work`, records it, and re-throws anything it throws — the
    /// wrapper for tool applies, where duration is as interesting as
    /// outcome.
    @discardableResult
    static func timed<T>(_ action: String, detail: [String: Any?] = [:], work: () throws -> T) rethrows -> T {
        let startedAt = Date()
        do {
            let value = try work()
            log(action, detail: detail, outcome: "success", durationMS: Int(Date().timeIntervalSince(startedAt) * 1000))
            return value
        } catch {
            var merged = detail
            merged["error"] = error.localizedDescription
            log(action, detail: merged, outcome: "failed", durationMS: Int(Date().timeIntervalSince(startedAt) * 1000))
            throw error
        }
    }
}
