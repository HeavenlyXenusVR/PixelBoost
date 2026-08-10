import SwiftUI
import WidgetKit

/// Home Screen widget: total upscale count + a thumbnail of the last
/// result, read from `UpscaleSnapshot` (App Group container the main app
/// writes to after every successful upscale — see
/// `UpscaleRunner.run`/`UpscaleSnapshot.record`). No network, no server
/// dependency — works the same whether or not the optional
/// upscaler-bridge server is configured.
struct UpscaleStatsEntry: TimelineEntry {
    let date: Date
    let totalUpscales: Int
    let lastResultThumbnail: UIImage?
}

struct UpscaleStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpscaleStatsEntry {
        UpscaleStatsEntry(date: Date(), totalUpscales: 0, lastResultThumbnail: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpscaleStatsEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpscaleStatsEntry>) -> Void) {
        // A widget has no way to know when the app last upscaled something,
        // so this just refreshes periodically rather than on a precise
        // schedule — WidgetKit coalesces/rate-limits actual refreshes well
        // below this anyway on real devices.
        let entry = currentEntry()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> UpscaleStatsEntry {
        let snapshot = UpscaleSnapshot.load()
        return UpscaleStatsEntry(
            date: Date(),
            totalUpscales: snapshot?.totalUpscales ?? 0,
            lastResultThumbnail: UpscaleSnapshot.loadLastResultThumbnail()
        )
    }
}

struct UpscaleStatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UpscaleStatsEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        default:
            homeScreenView
        }
    }

    /// Lock Screen circular complication — just the count, no thumbnail
    /// (too small to read one at that size anyway).
    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("\(entry.totalUpscales)")
                    .font(.system(size: 20, weight: .bold))
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
            }
        }
    }

    /// Lock Screen rectangular complication.
    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("PixelBoost", systemImage: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
            Text("\(entry.totalUpscales) upscaled")
                .font(.system(size: 14, weight: .bold))
        }
    }

    private var homeScreenView: some View {
        ZStack {
            if let thumbnail = entry.lastResultThumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .overlay(Color.black.opacity(0.35))
            } else {
                Color(red: 0.086, green: 0.086, blue: 0.106)
            }

            VStack(alignment: .leading, spacing: 2) {
                Spacer()
                Text("\(entry.totalUpscales)")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white)
                Text(entry.totalUpscales == 1 ? "Photo Upscaled" : "Photos Upscaled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(for: .widget) {
            Color(red: 0.086, green: 0.086, blue: 0.106)
        }
    }
}

struct UpscaleStatsWidget: Widget {
    let kind = "UpscaleStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpscaleStatsProvider()) { entry in
            UpscaleStatsWidgetView(entry: entry)
        }
        .configurationDisplayName("PixelBoost Stats")
        .description("Shows your total upscale count and the most recent result.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
