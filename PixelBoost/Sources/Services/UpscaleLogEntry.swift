import Foundation

/// Mirrors `UpscaleLogEntry` (the Pydantic model) in server/main.py field
/// for field — keep the two in sync.
struct UpscaleLogEntry: Encodable {
    let device_id: String
    let source_width: Int
    let source_height: Int
    let source_file_size_bytes: Int?
    let technique: String
    let model_name: String?
    let tile_size: Int?
    let overlap: Int?
    let scale_factor: Int
    let tile_count: Int?
    let output_width: Int?
    let output_height: Int?
    let processing_ms: Int
    let success: Bool
    let error_message: String?
    let app_version: String?
    let os_version: String?
    let device_model: String?
    // Run context (see server/schema.sql's 2026-09-22 section). Defaulted
    // so the handful of call sites that only have the basics still compile.
    var session_id: String? = TelemetryService.sessionID
    var detail_level: String? = nil
    /// What the model actually saw, after any detail-budget downscale.
    /// Between `source_*` and `output_*` there was no way to tell a real
    /// full-resolution run from one where the photo had been shrunk to a
    /// fraction of its size first — exactly the regression shipped in
    /// v3.26.13-v3.26.17.
    var model_input_width: Int? = nil
    var model_input_height: Int? = nil
    var requested_scale: Int? = nil
    var upscale_strength: Double? = nil
    var anti_aliasing: Double? = nil
    var sharpen: Double? = nil
    var denoise_before: Bool? = nil
    var was_batch: Bool? = nil
    var cancelled: Bool? = nil
    var thermal_state_start: String? = nil
    var thermal_state_end: String? = nil
    var low_power_mode: Bool? = nil
    var battery_level: Double? = nil
    var physical_memory_mb: Int? = nil
    var peak_memory_mb: Int? = nil
    // Per-model run telemetry (see server/schema.sql's 2026-10-04 section).
    /// 'single' | 'batch' | 'compare' | 'live'. Auto mode and Compare
    /// Models run every bundled model over the full photo, and each of
    /// those candidate runs used to land here looking exactly like a
    /// deliberate single upscale — so every per-model aggregate mixed one
    /// requested run in with a whole sweep the user never asked for
    /// individually. `was_batch` is still set alongside this.
    var run_kind: String? = nil
    /// Set on compare/auto-sweep rows, joining them to the
    /// `model_comparisons` row for the sweep they belong to.
    var comparison_id: String? = nil
    /// From `UpscaleResult` — all four were already being computed per run
    /// and then discarded at the log boundary.
    var fidelity_psnr: Double? = nil
    var tiles_reused: Int? = nil
    var output_was_capped: Bool? = nil
    var render_denoise_applied: Bool? = nil
    /// The estimated noise level that decided whether the render-denoise
    /// pass ran — without it, `render_denoise_applied` records what
    /// happened but not why, so a badly-set threshold stays invisible.
    var source_noise_sigma: Double? = nil
    var free_disk_mb: Int? = nil
}
