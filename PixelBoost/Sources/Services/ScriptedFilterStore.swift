import Foundation

/// One named Lua script saved by the user (see `LuaFilterEngine`).
struct SavedLuaScript: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var code: String

    init(id: UUID = UUID(), name: String, code: String) {
        self.id = id
        self.name = name
        self.code = code
    }
}

/// Local-only persistence for saved scripts — plain `UserDefaults` JSON,
/// the same "just one small blob" approach `ICloudPresetStore` uses for its
/// own list, just backed by `UserDefaults` instead of
/// `NSUbiquitousKeyValueStore` since there's no cross-device sync need
/// here (a script is small, freely copy-paste-able text — nothing worth
/// wiring a server or iCloud round-trip for).
enum ScriptedFilterStore {
    private static let key = "com.pixelboost.savedLuaScripts"

    static func load() -> [SavedLuaScript] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return defaultScripts }
        return (try? JSONDecoder().decode([SavedLuaScript].self, from: data)) ?? defaultScripts
    }

    static func save(_ scripts: [SavedLuaScript]) {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// A couple of ready-to-run examples so the tool isn't a blank text box
    /// the first time anyone opens it.
    static let defaultScripts: [SavedLuaScript] = [
        SavedLuaScript(
            name: "Invert",
            code: "function apply(r, g, b, a)\n  return 1 - r, 1 - g, 1 - b, a\nend"
        ),
        SavedLuaScript(
            name: "Red Channel Only",
            code: "function apply(r, g, b, a)\n  return r, 0, 0, a\nend"
        ),
        SavedLuaScript(
            name: "Threshold (B&W)",
            code: "function apply(r, g, b, a)\n  local lum = 0.299 * r + 0.587 * g + 0.114 * b\n  local v = lum > 0.5 and 1 or 0\n  return v, v, v, a\nend"
        ),
    ]
}
