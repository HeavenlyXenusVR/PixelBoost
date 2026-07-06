import PhotosUI
import SwiftUI

struct BatchUpscaleView: View {
    @StateObject private var viewModel: BatchUpscaleViewModel
    @State private var pickerItems: [PhotosPickerItem] = []

    /// `provider` is passed in explicitly from the parent (which reads it
    /// via @EnvironmentObject) rather than this view reading environment
    /// itself, since a @StateObject needs its wrapped value's dependencies
    /// at init time, before environment values are available.
    init(provider: UpscalerProvider) {
        _viewModel = StateObject(wrappedValue: BatchUpscaleViewModel(provider: provider))
    }

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                    Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(viewModel.isRunning)
                .onChange(of: pickerItems) { newValue in
                    viewModel.setSelection(newValue)
                }

                if !viewModel.items.isEmpty {
                    Button {
                        Haptics.lightImpact()
                        viewModel.runAll()
                    } label: {
                        Label(
                            viewModel.isRunning ? "Upscaling…" : "Upscale All (\(viewModel.items.count))",
                            systemImage: "wand.and.stars"
                        )
                    }
                    .disabled(viewModel.isRunning)
                }
            } footer: {
                Text("Each result saves straight to Photos as it finishes, up to 20 photos per batch.")
            }

            if !viewModel.items.isEmpty {
                Section("Queue") {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        BatchItemRow(item: item, isCurrent: viewModel.currentIndex == index)
                    }
                }
            }
        }
        .navigationTitle("Batch Upscale")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BatchItemRow: View {
    let item: BatchUpscaleViewModel.Item
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(isFailed ? .red : .primary)
                .lineLimit(2)
            Spacer()
            if isCurrent {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        case .processing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
        case .done(let thumbnail):
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .frame(width: 32, height: 32)
        }
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var statusText: String {
        switch item.status {
        case .pending: return "Waiting…"
        case .processing: return "Upscaling…"
        case .done: return "Saved to Photos"
        case .failed(let message): return message
        }
    }
}
