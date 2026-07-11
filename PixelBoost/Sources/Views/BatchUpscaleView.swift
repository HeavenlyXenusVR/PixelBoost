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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PBCard {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                        PBCardRow(icon: "photo.on.rectangle.angled", label: "Choose Photos")
                    }
                    .disabled(viewModel.isRunning)
                    .onChange(of: pickerItems) { newValue in
                        viewModel.setSelection(newValue)
                    }

                    if !viewModel.items.isEmpty {
                        PBRowDivider()
                        Button {
                            Haptics.lightImpact()
                            viewModel.runAll()
                        } label: {
                            PBCardRow(
                                icon: "wand.and.stars", iconTint: PBColor.accent2,
                                label: viewModel.isRunning ? "Upscaling…" : "Upscale All (\(viewModel.items.count))"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isRunning)
                    }
                }
                PBFootnote(text: "Each result saves straight to Photos as it finishes, up to 20 photos per batch.")

                if !viewModel.items.isEmpty {
                    PBSectionLabel(title: "Queue (\(doneCount)/\(viewModel.items.count))")
                    ProgressView(value: Double(doneCount), total: Double(viewModel.items.count))
                        .tint(PBColor.accent)
                        .padding(.horizontal, 2)

                    VStack(spacing: 8) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            BatchItemCard(item: item, isCurrent: viewModel.currentIndex == index)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(PBColor.background.ignoresSafeArea())
        .navigationTitle("Batch Upscale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PBColor.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    private var doneCount: Int {
        viewModel.items.filter {
            if case .done = $0.status { return true }
            return false
        }.count
    }
}

private struct BatchItemCard: View {
    let item: BatchUpscaleViewModel.Item
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            statusRing
            Text(statusText)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isFailed ? PBColor.bad : PBColor.ink)
                .lineLimit(2)
            Spacer()
            if isCurrent {
                ProgressView().tint(PBColor.accent)
            }
        }
        .padding(11)
        .background(PBColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PBColor.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusRing: some View {
        switch item.status {
        case .pending:
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .foregroundStyle(PBColor.surface3)
                .frame(width: 30, height: 30)
        case .processing:
            Circle()
                .stroke(PBColor.accent, lineWidth: 2)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PBColor.accent)
                )
        case .done(let thumbnail):
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .failed:
            Circle()
                .fill(PBColor.bad.opacity(0.15))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PBColor.bad)
                )
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
