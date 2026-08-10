import ActivityKit
import Foundation

/// Thin wrapper over `Activity<BatchUpscaleActivityAttributes>` — starts a
/// Live Activity when a batch run begins, updates it as each item
/// finishes, ends it when the queue drains. Every call is best-effort:
/// Live Activities can be denied by the user (Settings toggle) or simply
/// unsupported (older OS), and none of that should ever block or fail the
/// actual upscale queue it's just reporting on — same "logging must never
/// affect the thing it's describing" reasoning as `ActionLoggingService`.
enum BatchLiveActivityController {
    private static var current: Activity<BatchUpscaleActivityAttributes>?

    static func start(totalCount: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = BatchUpscaleActivityAttributes(startedAt: Date())
        let initialState = BatchUpscaleActivityAttributes.ContentState(
            completedCount: 0, totalCount: totalCount, currentFileName: nil
        )
        current = try? Activity.request(
            attributes: attributes,
            content: .init(state: initialState, staleDate: nil)
        )
    }

    static func update(completedCount: Int, totalCount: Int) {
        guard let current else { return }
        let state = BatchUpscaleActivityAttributes.ContentState(
            completedCount: completedCount, totalCount: totalCount, currentFileName: nil
        )
        Task { await current.update(.init(state: state, staleDate: nil)) }
    }

    static func end(completedCount: Int, totalCount: Int) {
        guard let current else { return }
        let finalState = BatchUpscaleActivityAttributes.ContentState(
            completedCount: completedCount, totalCount: totalCount, currentFileName: nil
        )
        Task {
            await current.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 5))
        }
        self.current = nil
    }
}
