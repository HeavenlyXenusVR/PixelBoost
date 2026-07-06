import Foundation

/// Points at a deployed `upscaler-bridge` instance (see server/README.md in
/// the repo) — a user-set setting rather than a compiled-in constant, since
/// nothing is deployed yet and the eventual host isn't known at build time.
/// Empty (the default) means logging is simply skipped.
enum ServerConfig {
    static let baseURLDefaultsKey = "com.imageupscaler.serverBaseURL"

    static var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: baseURLDefaultsKey),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
