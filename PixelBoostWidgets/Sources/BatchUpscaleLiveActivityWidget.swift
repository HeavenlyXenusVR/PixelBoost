import ActivityKit
import SwiftUI
import WidgetKit

/// Renders `BatchUpscaleActivityAttributes` (see PixelBoost/Sources/Shared)
/// on the Lock Screen/Dynamic Island — started/updated/ended by
/// `BatchLiveActivityController` from `BatchUpscaleViewModel.runAll()`.
struct BatchUpscaleLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BatchUpscaleActivityAttributes.self) { context in
            lockScreenView(context.state)
                .padding(16)
                .activityBackgroundTint(Color(red: 0.086, green: 0.086, blue: 0.106))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.completedCount)/\(context.state.totalCount)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    progressBar(context.state)
                }
            } compactLeading: {
                Image(systemName: "wand.and.stars")
            } compactTrailing: {
                Text("\(context.state.completedCount)/\(context.state.totalCount)")
                    .font(.system(size: 12, weight: .bold))
            } minimal: {
                Image(systemName: "wand.and.stars")
            }
        }
    }

    private func lockScreenView(_ state: BatchUpscaleActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Batch Upscale", systemImage: "wand.and.stars")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(state.completedCount)/\(state.totalCount)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            progressBar(state)
        }
    }

    private func progressBar(_ state: BatchUpscaleActivityAttributes.ContentState) -> some View {
        ProgressView(value: state.totalCount > 0 ? Double(state.completedCount) / Double(state.totalCount) : 0)
            .progressViewStyle(.linear)
            .tint(.white)
    }
}
