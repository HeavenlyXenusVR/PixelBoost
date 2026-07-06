import Foundation

/// This app has no user accounts, so there's no real user identity to key
/// server-side logs on — just a random UUID generated once per install and
/// persisted locally, purely to group one device's history together and let
/// `GET /log/history?device_id=...` filter to it.
enum DeviceIdentity {
    private static let defaultsKey = "com.imageupscaler.deviceID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: defaultsKey)
        return generated
    }
}
