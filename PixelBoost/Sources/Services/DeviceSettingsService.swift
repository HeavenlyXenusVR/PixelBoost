import Foundation

/// A manually-triggered backup/restore slot for this device's settings —
/// there's no account system, so this is per-`device_id`, not automatic
/// multi-device sync. See server/schema.sql's `device_settings` table.
struct DeviceSettingsBackup: Codable {
    let device_id: String
    let haptics_enabled: Bool
    let model_choice: String
    let quality: String
}

enum DeviceSettingsService {
    static func backup(hapticsEnabled: Bool, modelChoice: UpscaleModelChoice, quality: UpscaleQuality) async throws {
        var request = try APIClient.request(path: "device-settings", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeviceSettingsBackup(
                device_id: DeviceIdentity.current,
                haptics_enabled: hapticsEnabled,
                model_choice: modelChoice.rawValue,
                quality: quality.rawValue
            )
        )
        _ = try await APIClient.data(for: request)
    }

    /// Throws `APIError.badStatus(404, _)` if this device has never backed
    /// up before — callers should surface that as "no backup found" rather
    /// than a generic failure.
    static func restore() async throws -> DeviceSettingsBackup {
        let request = try APIClient.request(path: "device-settings", queryItems: [
            URLQueryItem(name: "device_id", value: DeviceIdentity.current),
        ])
        let data = try await APIClient.data(for: request)
        return try JSONDecoder().decode(DeviceSettingsBackup.self, from: data)
    }
}
