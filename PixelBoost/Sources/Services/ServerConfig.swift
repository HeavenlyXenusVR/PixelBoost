import Foundation

/// Points at the deployed `upscaler-bridge` instance (see server/README.md
/// in the repo). Both values are overridable per-install via Settings —
/// the base URL via `@AppStorage` against `baseURLDefaultsKey`, the API key
/// via `userOverride` below (Keychain-backed) — e.g. to point a dev build
/// at a local instance.
enum ServerConfig {
    static let baseURLDefaultsKey = "com.pixelboost.serverBaseURL"
    static let apiKeyDefaultsKey = "com.pixelboost.serverAPIKey"

    /// Just a hostname, not a secret — safe to bake in directly.
    static let defaultBaseURLString = "https://upscaler-bridge.xenusanimations.studio"

    /// nil disables logging entirely — only possible by explicitly clearing
    /// the Settings field, since there's always a baked-in default.
    static var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: baseURLDefaultsKey) ?? defaultBaseURLString
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// nil means "don't send an Authorization header" — matches the
    /// server's check_auth, which only enforces auth when its own
    /// UPSCALER_BRIDGE_API_KEY env var is set. The real key, if any, is
    /// injected at CI build time into Info.plist's UpscalerBridgeAPIKey
    /// from the UPSCALER_BRIDGE_API_KEY repo secret — it's never written to
    /// a file in this repo. Local/dev builds get an empty string here (see
    /// project.yml) and so send no header, same as if logging had no auth.
    ///
    /// A user-entered override (Settings' API key field) lives in the
    /// Keychain, not `UserDefaults` — unlike the base URL, a self-hosted
    /// user's key is a real secret and `UserDefaults` backs a plain,
    /// unencrypted plist on disk. `apiKeyDefaultsKey` is kept only as a
    /// one-time migration source for anyone who set a key before this
    /// changed; `userOverride`'s setter clears it from `UserDefaults` right
    /// after moving it, so nothing sensitive lingers there afterward.
    static var apiKey: String? {
        let fromInfoPlist = Bundle.main.infoDictionary?["UpscalerBridgeAPIKey"] as? String
        let key = userOverride ?? fromInfoPlist ?? ""
        return key.isEmpty ? nil : key
    }

    static var userOverride: String? {
        get {
            if let migrated = UserDefaults.standard.string(forKey: apiKeyDefaultsKey), !migrated.isEmpty {
                KeychainStore.setString(migrated, forAccount: apiKeyDefaultsKey)
                UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
                return migrated
            }
            return KeychainStore.string(forAccount: apiKeyDefaultsKey)
        }
        set { KeychainStore.setString(newValue, forAccount: apiKeyDefaultsKey) }
    }
}
