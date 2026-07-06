import Foundation

/// A user-named model+overlap combination beyond the built-in Fast/
/// Standard/Best presets — see server/schema.sql's `custom_presets` table.
struct CustomPreset: Decodable, Identifiable {
    let id: String
    let device_id: String
    let name: String
    let model_name: String
    let overlap: Int
    let created_at: String
}

private struct CustomPresetListResponse: Decodable {
    let entries: [CustomPreset]
}

private struct CustomPresetCreateResponse: Decodable {
    let id: String
}

private struct CustomPresetCreateRequest: Encodable {
    let device_id: String
    let name: String
    let model_name: String
    let overlap: Int
}

enum CustomPresetService {
    /// Upserts by `(device_id, name)` — creating a preset with an existing
    /// name updates it in place, matching the server's `ON DUPLICATE KEY
    /// UPDATE` behavior.
    @discardableResult
    static func save(name: String, modelName: String, overlap: Int) async throws -> String {
        var request = try APIClient.request(path: "presets", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CustomPresetCreateRequest(device_id: DeviceIdentity.current, name: name, model_name: modelName, overlap: overlap)
        )
        let data = try await APIClient.data(for: request)
        return try JSONDecoder().decode(CustomPresetCreateResponse.self, from: data).id
    }

    static func fetchOwn() async throws -> [CustomPreset] {
        let request = try APIClient.request(path: "presets", queryItems: [
            URLQueryItem(name: "device_id", value: DeviceIdentity.current),
        ])
        let data = try await APIClient.data(for: request)
        return try JSONDecoder().decode(CustomPresetListResponse.self, from: data).entries
    }

    static func delete(id: String) async throws {
        let request = try APIClient.request(path: "presets/\(id)", method: "DELETE")
        _ = try await APIClient.data(for: request)
    }
}
