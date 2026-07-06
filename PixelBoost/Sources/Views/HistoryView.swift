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
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty && !isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No history yet")
                        .font(.headline)
                    Text("Upscale a photo and it'll show up here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let stats {
                        Section {
                            StatsHeaderView(stats: stats)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                    Section {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry)
                        }
                        .onDelete(perform: delete)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
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

private struct StatsHeaderView: View {
    let stats: UpscaleStats

    var body: some View {
        HStack(spacing: 0) {
            statColumn(value: "\(stats.total)", label: "Upscales")
            Divider()
            statColumn(value: successRateText, label: "Success")
            Divider()
            statColumn(value: avgTimeText, label: "Avg Time")
            Divider()
            statColumn(value: megapixelsText, label: "Megapixels")
        }
        .padding(.vertical, 12)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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

private struct HistoryRow: View {
    let entry: UpscaleHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.success ? .green : .red)
                Text(techniqueLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.created_at)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(entry.source_width)×\(entry.source_height) → \(outputSizeText) · \(entry.processing_ms) ms")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let tileCount = entry.tile_count {
                Text("\(tileCount) tile\(tileCount == 1 ? "" : "s"), \(entry.tile_size ?? 0)px, overlap \(entry.overlap ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = entry.error_message {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
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
