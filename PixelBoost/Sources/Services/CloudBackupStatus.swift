import Foundation

/// Tracks whether the most recent *automatic* cloud backup (Settings' "Auto
/// Cloud Backup" toggle — see `UpscalerViewModel.resultImage`'s `didSet` and
/// `UpscaleRunner.log`) succeeded, so a flaky connection doesn't fail
/// silently the way a plain `try?` would otherwise leave it. Manual
/// "Backup to Cloud" taps already surface their own error alert
/// (`ContentView.backupResultToCloud`) and don't go through this — this is
/// only for the unattended path, which has no user action to attach an
/// error to. Session-only by design (not persisted): a stale "backup
/// failed" banner from three app launches ago would be more confusing than
/// helpful once the user's since fixed their connection and moved on.
@MainActor
final class CloudBackupStatus: ObservableObject {
    static let shared = CloudBackupStatus()

    @Published private(set) var lastFailureMessage: String?

    private init() {}

    func reportSuccess() {
        lastFailureMessage = nil
    }

    func reportFailure(_ error: Error) {
        lastFailureMessage = error.localizedDescription
    }

    func dismiss() {
        lastFailureMessage = nil
    }
}
