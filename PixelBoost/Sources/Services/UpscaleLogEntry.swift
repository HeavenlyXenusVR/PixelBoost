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
}
