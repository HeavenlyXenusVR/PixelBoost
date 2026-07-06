import UIKit

/// Thin wrapper around UIKit's feedback generators, gated by a Settings
/// toggle (default on).
enum Haptics {
    static let enabledDefaultsKey = "com.pixelboost.hapticsEnabled"

    private static var isEnabled: Bool {
        // No stored value yet (first launch, before Settings is ever
        // opened) means "on" — only an explicit user toggle-off disables
        // this, so the check can't just be `bool(forKey:)`, which defaults
        // to false for an absent key.
        UserDefaults.standard.object(forKey: enabledDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func lightImpact() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
