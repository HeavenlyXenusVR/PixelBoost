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

    var body: some View {
        VStack(spacing: 0) {
            segmentedControl
                .padding(16)

            Group {
                if let errorMessage {
                    emptyState(systemImage: "exclamationmark.triangle", title: nil, message: errorMessage)
                } else if entries.isEmpty && !isLoading {
                    emptyState(
                        systemImage: "icloud", title: "Nothing here yet",
                        message: "Back up a photo from the main screen and it'll show up here until it expires."
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
        .background(PBColor.background.ignoresSafeArea())
        .navigationTitle("Cloud Storage")
        .navigationBarTitleDisplayMode(.inline)
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
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isActive ? .white : PBColor.inkDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isActive ? AnyShapeStyle(PBColor.accentGradient) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
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
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await ImportExportService.list(kind: kind)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func downloadAndPreview(_ entry: StoredImageEntry) async {
        do {
            previewImage = try await ImportExportService.download(id: entry.id, kind: kind)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
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
                Text("\(entry.width)×\(entry.height) · \(formattedSize)")
                    .font(.system(size: 11))
                    .foregroundStyle(PBColor.inkDim)
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
        .background(PBColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PBColor.line, lineWidth: 1)
        )
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
