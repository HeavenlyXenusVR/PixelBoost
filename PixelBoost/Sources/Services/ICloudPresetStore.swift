import Foundation

/// A locally-defined upscale preset (name + model + overlap), synced across
/// a user's devices via iCloud's key-value store — no server or account
/// needed beyond already being signed into iCloud, unlike
/// `CustomPresetService`'s server-backed presets (see `CustomPresetsCard`,
/// which requires a configured server). Uses its own UUID ids, independent
/// of `CustomPreset`'s server-assigned String ids — the two storage
/// backends are unrelated and never need to reconcile with each other.
struct ICloudPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var modelName: String
    var overlap: Int
    var updatedAt: Date

    init(name: String, modelName: String, overlap: Int) {
        id = UUID()
        self.name = name
        self.modelName = modelName
        self.overlap = overlap
        updatedAt = Date()
    }
}

/// Stores the whole preset list as one JSON blob under a single
/// `NSUbiquitousKeyValueStore` key, rather than a per-preset key scheme —
/// KVS is meant for small aggregate data (Apple caps the whole store around
/// 1MB), and a handful of presets easily fits as one blob. Whichever
/// device's write lands last wins for the *entire* list (no per-preset
/// merge) — an acceptable simplification for a small, low-conflict,
/// single-user list, and one that can't be checked against real
/// multi-device sync behavior here anyway (no second device/iCloud account
/// available to test with — see README's "Known simplifications").
@MainActor
final class ICloudPresetStore: ObservableObject {
    static let shared = ICloudPresetStore()

    @Published private(set) var presets: [ICloudPreset] = []

    private let store = NSUbiquitousKeyValueStore.default
    private let key = "pixelboost.presets.v1"
    private var observer: NSObjectProtocol?

    private init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        store.synchronize()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func save(name: String, modelName: String, overlap: Int) {
        var current = presets
        current.append(ICloudPreset(name: name, modelName: modelName, overlap: overlap))
        persist(current)
    }

    func delete(_ preset: ICloudPreset) {
        persist(presets.filter { $0.id != preset.id })
    }

    private func reload() {
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ICloudPreset].self, from: data) else {
            presets = []
            return
        }
        presets = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist(_ list: [ICloudPreset]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        store.set(data, forKey: key)
        store.synchronize()
        presets = list.sorted { $0.updatedAt > $1.updatedAt }
    }
}
