import Foundation
import UIKit

/// Posts one Compare Models / Auto sweep to `upscaler-bridge` — see
/// server/README.md's "Per-model comparison telemetry" endpoints.
///
/// The individual candidate runs already go to `upscale_history` through
/// `UpscaleRunner` (tagged with the same `comparisonID` and
/// `run_kind: "compare"`). This posts the *sweep*: every model that ran
/// side by side on the same photo, their scores and timings together, and
/// — via `recordPick` — which result the user actually chose.
///
/// That last part is the only non-proxy signal this app has about model
/// quality. `sharpnessScore` is a heuristic standing in for "looks better";
/// a human picking one of six results they can all see is the real answer,
/// and it was not being recorded anywhere.
///
/// Same best-effort, never-throws contract as the rest of the logging
/// here: a failure prints and is dropped, and posts nothing at all when
/// Diagnostics is off or no server is configured.
enum ComparisonLoggingService {
    static func log(_ payload: ComparisonLogPayload) async {
        guard TelemetryService.isEnabled else { return }
        do {
            var request = try APIClient.request(path: "log/comparison", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            _ = try await APIClient.data(for: request)
        } catch {
            print("ComparisonLoggingService: failed to log comparison — \(error.localizedDescription)")
        }
    }

    /// Records which model's result the user picked out of `comparisonID`'s
    /// sweep. Separate from `log` because the pick happens later (in
    /// `ModelComparisonView`, whenever the user gets around to choosing)
    /// and may never happen at all — backing out without choosing is
    /// itself an outcome the server can count.
    static func recordPick(comparisonID: String, modelName: String) async {
        guard TelemetryService.isEnabled else { return }
        do {
            var request = try APIClient.request(
                path: "log/comparison/\(comparisonID)/pick", method: "POST"
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model_name": modelName])
            _ = try await APIClient.data(for: request)
        } catch {
            print("ComparisonLoggingService: failed to log pick — \(error.localizedDescription)")
        }
    }
}

/// Mirrors the server's `ComparisonCandidate` (see server/main.py).
struct ComparisonCandidatePayload: Encodable {
    let model_name: String
    let candidate_index: Int
    let succeeded: Bool
    var processing_ms: Int? = nil
    /// The variance-of-Laplacian crop score Compare Models ranks by (see
    /// `UpscalerProvider.sharpnessScore`) — recorded so the ranking can be
    /// checked against the user's pick rather than trusted.
    var sharpness_score: Double? = nil
    var fidelity_psnr: Double? = nil
    var tile_count: Int? = nil
    var tiles_reused: Int? = nil
    var render_denoise_applied: Bool? = nil
    var error_message: String? = nil
}

/// Mirrors the server's `ComparisonLogEntry` (see server/main.py).
struct ComparisonLogPayload: Encodable {
    let comparison_id: String
    let device_id: String
    var session_id: String? = TelemetryService.sessionID
    var source_width: Int? = nil
    var source_height: Int? = nil
    var cancelled: Bool? = false
    var total_ms: Int? = nil
    /// What the content-affinity heuristic would have picked on its own
    /// (see `UpscalerProvider.autoSelectModel`), stored next to the user's
    /// actual pick so the two can be compared directly.
    var auto_pick_model: String? = nil
    var source_noise_sigma: Double? = nil
    var thermal_state_start: String? = nil
    var thermal_state_end: String? = nil
    var app_version: String? = TelemetryService.appVersion
    var os_version: String? = nil
    var device_model: String? = nil
    var candidates: [ComparisonCandidatePayload] = []
}
