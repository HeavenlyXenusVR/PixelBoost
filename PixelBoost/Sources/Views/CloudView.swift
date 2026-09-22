import SwiftUI
import UIKit

/// Browses this device's temporary cloud storage (`image_imports`/
/// `image_exports` on `upscaler-bridge`) — opt-in scratch storage that
/// auto-expires, not a sync mechanism or photo library.
struct CloudView: View {
    @State private var kind: ImportExportService.Kind = .imports
    @State private var entries: [StoredImageEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var previewImage: UIImage?
    @State private var usage: StoredImageUsage?
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            segmentedControl
                .padding(.horizontal, 16)
                .padding(.top, 16)
            usageSummary
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Group {
                if let errorMessage {
                    emptyState(systemImage: "exclamationmark.triangle", title: nil, message: errorMessage)
                } else if entries.isEmpty && !isLoading {
                    emptyState(
                        systemImage: "icloud", title: "Nothing here yet",
                        message: "Upscale results are kept here for a day when Temporary Cloud Save is on, and you can back up a photo manually from the main screen. Everything here deletes itself when it expires."
                    )
                } else {
                    List {
                        ForEach(entries) { entry in
                            Button {
                                Task { await downloadAndPreview(entry) }
                            } label: {
                                CloudCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pbReserveTabBarSpace()
        .background(PBColor.background.ignoresSafeArea())
        .navigationTitle("Cloud Storage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear All", role: .destructive) { isConfirmingClear = true }
                        .foregroundStyle(PBColor.warn)
                }
            }
        }
        .confirmationDialog(
            "Delete every \(kind == .imports ? "import" : "result") stored for this device?",
            isPresented: $isConfirmingClear, titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { Task { await clearAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These expire on their own anyway — this just deletes them now. Photos saved to your library aren't affected.")
        }
        .toolbarBackground(PBColor.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: kind) { await load() }
        .refreshable { await load() }
        .fullScreenCover(isPresented: Binding(
            get: { previewImage != nil },
            set: { isPresented in if !isPresented { previewImage = nil } }
        )) {
            if let previewImage {
                ZoomableImageView(image: previewImage)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Real totals rather than a vague reassurance: this screen's whole
    /// premise is that everything on it is scheduled for deletion, so how
    /// much is here and when the next thing goes are the two facts worth
    /// showing.
    @ViewBuilder
    private var usageSummary: some View {
        if let bucket = kind == .imports ? usage?.imports : usage?.exports, bucket.count > 0 {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(bucket.count) item\(bucket.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(bucket.total_bytes), countStyle: .file)) · auto-deleted as each expires")
                    .font(.system(size: 11))
            }
            .foregroundStyle(PBColor.inkDim)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segment("Imports", isActive: kind == .imports) { kind = .imports }
            segment("Exports", isActive: kind == .exports) { kind = .exports }
        }
        .padding(3)
        .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func segment(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let text = Text(title)
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            if isActive {
                text.pbAccentGlow(cornerRadius: 9)
            } else {
                text.foregroundStyle(PBColor.inkDim)
            }
        }
        .buttonStyle(.plain)
    }

    private func emptyState(systemImage: String, title: String?, message: String) -> some View {
        PBEmptyState(icon: systemImage, title: title, message: message)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await ImportExportService.list(kind: kind)
            usage = try? await ImportExportService.usage()
            ActionLoggingService.log("cloud_list", detail: [
                "kind": kind.rawValue, "count": entries.count,
            ], outcome: "success")
        } catch {
            errorMessage = error.localizedDescription
            ActionLoggingService.log("cloud_list", detail: [
                "kind": kind.rawValue, "error": error.localizedDescription,
            ], outcome: "failed")
        }
        isLoading = false
    }

    private func downloadAndPreview(_ entry: StoredImageEntry) async {
        let startedAt = Date()
        do {
            previewImage = try await ImportExportService.download(id: entry.id, kind: kind)
            ActionLoggingService.log(
                "cloud_download", detail: ["kind": kind.rawValue, "bytes": entry.file_size_bytes],
                outcome: "success", durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
            )
        } catch {
            errorMessage = error.localizedDescription
            ActionLoggingService.log("cloud_download", detail: [
                "kind": kind.rawValue, "error": error.localizedDescription,
            ], outcome: "failed")
        }
    }

    private func clearAll() async {
        do {
            let deleted = try await ImportExportService.clearAll(kind: kind)
            entries = []
            usage = try? await ImportExportService.usage()
            ActionLoggingService.log("cloud_clear_all", detail: [
                "kind": kind.rawValue, "deleted": deleted,
            ], outcome: "success")
        } catch {
            errorMessage = error.localizedDescription
            ActionLoggingService.log("cloud_clear_all", detail: [
                "kind": kind.rawValue, "error": error.localizedDescription,
            ], outcome: "failed")
        }
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        ActionLoggingService.log("cloud_delete", detail: ["kind": kind.rawValue, "count": toDelete.count])
        Task {
            for entry in toDelete {
                try? await ImportExportService.delete(id: entry.id, kind: kind)
            }
        }
    }
}

private struct CloudCard: View {
    let entry: StoredImageEntry

    /// The server pins its DB session to UTC (see server/db.py) and every
    /// timestamp it returns is a bare "yyyy-MM-dd'T'HH:mm:ss" with no
    /// offset marker — so this must be told UTC explicitly rather than
    /// using `ISO8601DateFormatter`, which requires an offset/`Z` in the
    /// string itself and would fail to parse this format at all.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [PBColor.accent2, PBColor.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename ?? "Untitled")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(PBColor.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(entry.width)×\(entry.height) · \(formattedSize)")
                        .font(.system(size: 11))
                        .foregroundStyle(PBColor.inkDim)
                    if entry.is_auto == true {
                        Text("AUTO")
                            .font(.system(size: 8.5, weight: .black))
                            .foregroundStyle(PBColor.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(PBColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                if let label = entry.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(PBColor.inkDim)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(expiryText)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(expiryIsSoon ? PBColor.warn : PBColor.good)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((expiryIsSoon ? PBColor.warn : PBColor.good).opacity(0.14), in: Capsule())
        }
        .padding(11)
        .pbGlassSurface(cornerRadius: 18)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(entry.file_size_bytes), countStyle: .file)
    }

    private var expiryDate: Date? {
        Self.dateFormatter.date(from: entry.expires_at)
    }

    private var expiryText: String {
        guard let expiryDate else { return "Unknown" }
        let remaining = expiryDate.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let hours = Int(remaining / 3600)
        if hours < 1 { return "<1h" }
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private var expiryIsSoon: Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSinceNow < 3600 * 6
    }
}
