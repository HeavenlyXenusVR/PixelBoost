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
}
