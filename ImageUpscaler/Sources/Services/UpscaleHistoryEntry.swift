import Foundation

/// One row from `GET /log/history` — a superset of `UpscaleLogEntry` (adds
/// the server-assigned `id`/`created_at`). See server/main.py's
/// `get_history` for the exact response shape.
struct UpscaleHistoryEntry: Decodable, Identifiable {
    let id: String
    let device_id: String
    let created_at: String
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

private struct UpscaleHistoryResponse: Decodable {
    let entries: [UpscaleHistoryEntry]
}

enum UpscaleHistoryService {
    enum FetchError: LocalizedError {
        case noServerConfigured
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .noServerConfigured:
                return "No server configured — set one in Settings first."
            case .badStatus(let code):
                return "Server returned status \(code)."
            }
        }
    }

    /// Fetches this device's own history only — there's no auth/accounts
    /// here, so scoping to `DeviceIdentity.current` is the only thing
    /// standing between one install and every other install's rows.
    static func fetchOwnHistory(limit: Int = 50) async throws -> [UpscaleHistoryEntry] {
        guard let baseURL = ServerConfig.baseURL else { throw FetchError.noServerConfigured }
        var components = URLComponents(url: baseURL.appendingPathComponent("log/history"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "device_id", value: DeviceIdentity.current),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { throw FetchError.noServerConfigured }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(UpscaleHistoryResponse.self, from: data).entries
    }
}
