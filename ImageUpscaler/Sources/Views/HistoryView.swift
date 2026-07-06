import SwiftUI

struct HistoryView: View {
    @State private var entries: [UpscaleHistoryEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                List(entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await UpscaleHistoryService.fetchOwnHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
