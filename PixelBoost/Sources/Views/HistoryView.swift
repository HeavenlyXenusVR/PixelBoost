import SwiftUI

struct HistoryView: View {
    @State private var entries: [UpscaleHistoryEntry] = []
    @State private var stats: UpscaleStats?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isPresentingClearConfirmation = false

    var body: some View {
        Group {
            if let errorMessage {
                emptyState(systemImage: "exclamationmark.triangle", title: nil, message: errorMessage)
            } else if entries.isEmpty && !isLoading {
                emptyState(
                    systemImage: "clock.arrow.circlepath", title: "No history yet",
                    message: "Upscale a photo and it'll show up here."
                )
            } else {
                // A styled List, not a plain ScrollView, so swipe-to-delete
                // and pull-to-refresh stay free instead of hand-rolled.
                List {
                    if let stats {
                        Section {
                            StatsStrip(stats: stats)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(entries) { entry in
                            HistoryCard(entry: entry)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                        .onDelete(perform: delete)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(PBColor.background.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PBColor.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    isPresentingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all history?", isPresented: $isPresentingClearConfirmation, titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text("This deletes every logged upscale attempt for this device. It can't be undone.")
        }
        .preferredColorScheme(.dark)
    }

    private func emptyState(systemImage: String, title: String?, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(PBColor.inkFaint)
            if let title {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(PBColor.ink)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(PBColor.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PBColor.background.ignoresSafeArea())
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let entriesFetch = UpscaleHistoryService.fetchOwnHistory()
            async let statsFetch = UpscaleStatsService.fetchOwn()
            (entries, stats) = try await (entriesFetch, statsFetch)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        Task {
            for entry in toDelete {
                try? await UpscaleHistoryService.delete(id: entry.id)
            }
            stats = try? await UpscaleStatsService.fetchOwn()
        }
    }

    private func clearAll() async {
        do {
            try await UpscaleHistoryService.deleteAllOwn()
            entries = []
            stats = try? await UpscaleStatsService.fetchOwn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StatsStrip: View {
    let stats: UpscaleStats

    var body: some View {
        HStack(spacing: 8) {
            statCard(value: "\(stats.total)", label: "Upscales")
            statCard(value: successRateText, label: "Success")
            statCard(value: avgTimeText, label: "Avg Time")
            statCard(value: megapixelsText, label: "Megapixels")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(PBColor.ink)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(PBColor.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(PBColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PBColor.line, lineWidth: 1)
        )
    }

    private var successRateText: String {
        guard let rate = stats.success_rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    private var avgTimeText: String {
        guard let avg = stats.avg_processing_ms else { return "—" }
        if avg >= 1000 { return String(format: "%.1fs", avg / 1000) }
        return "\(Int(avg))ms"
    }

    private var megapixelsText: String {
        String(format: "%.1fMP", Double(stats.total_output_pixels) / 1_000_000)
    }
}

private struct HistoryCard: View {
    let entry: UpscaleHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.success ? PBColor.good : PBColor.bad)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(techniqueLabel)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(PBColor.ink)
                    Spacer()
                    Text(entry.created_at)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PBColor.inkFaint)
                }
                Text("\(entry.source_width)×\(entry.source_height) → \(outputSizeText) · \(entry.processing_ms) ms")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PBColor.inkDim)

                if let tileCount = entry.tile_count {
                    Text("\(tileCount) tile\(tileCount == 1 ? "" : "s"), \(entry.tile_size ?? 0)px, overlap \(entry.overlap ?? 0)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PBColor.inkFaint)
                }
                if let errorMessage = entry.error_message {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PBColor.bad)
                }
            }
        }
        .padding(12)
        .background(PBColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PBColor.line, lineWidth: 1)
        )
    }

    private var techniqueLabel: String {
        entry.model_name ?? entry.technique
    }

    private var outputSizeText: String {
        guard let width = entry.output_width, let height = entry.output_height else { return "—" }
        return "\(width)×\(height)"
    }
}

#Preview {
    NavigationStack { HistoryView() }
}
