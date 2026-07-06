import Foundation

/// Points at the deployed `upscaler-bridge` instance (see server/README.md
/// in the repo). Both values are overridable per-install via Settings
/// (@AppStorage against the same keys), e.g. to point a dev build at a
/// local instance.
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
    static var apiKey: String? {
        let fromInfoPlist = Bundle.main.infoDictionary?["UpscalerBridgeAPIKey"] as? String
        let key = UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? fromInfoPlist ?? ""
        return key.isEmpty ? nil : key
    }
}
