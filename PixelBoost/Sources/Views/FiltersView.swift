import SwiftUI

/// One-tap filter picker. Lives as its own persistent tab (see
/// `RootView`) — picking a filter previews it large above; "Apply" bakes
/// it onto the shared result and resets the picker back to "Original," so
/// you can keep trying looks or switch tabs whenever, no dismiss step.
struct FiltersView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var selectedFilter: PhotoFilter = .none
    @State private var previewImage: UIImage?
    @State private var previewSource: UIImage?
    @State private var thumbnailSource: UIImage?
    @State private var lastBase: UIImage?
    @State private var thumbnails: [PhotoFilter: UIImage] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    VStack(spacing: 20) {
                        PBImageFrame {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 340)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(PhotoFilter.allCases) { filter in
                                    filterThumbnail(filter)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Button {
                            Haptics.lightImpact()
                            apply()
                        } label: {
                            Label("Apply", systemImage: "checkmark")
                        }
                        .buttonStyle(.pbGradient)
                        .disabled(selectedFilter == .none)
                        .padding(.horizontal, 20)

                        Spacer()
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private func filterThumbnail(_ filter: PhotoFilter) -> some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail = thumbnails[filter] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black.opacity(0.2)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selectedFilter == filter ? PBColor.accent : PBColor.line,
                        lineWidth: selectedFilter == filter ? 2 : 1
                    )
            )

            Text(filter.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selectedFilter == filter ? PBColor.ink : PBColor.inkDim)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.lightImpact()
            selectedFilter = filter
            guard let previewSource else { return }
            previewImage = filter.apply(to: previewSource)
        }
    }

    /// Re-derives the preview/thumbnails from whichever photo is current.
    /// Guarded by object identity (`!==`) so switching tabs back and forth
    /// without anything actually changing doesn't redo all this for
    /// nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewSource = nil
            previewImage = nil
            thumbnailSource = nil
            thumbnails = [:]
            selectedFilter = .none
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        let preview = Self.downscaled(current, maxDimension: 800)
        previewSource = preview
        previewImage = preview
        selectedFilter = .none

        let thumbSource = Self.downscaled(current, maxDimension: 160)
        thumbnailSource = thumbSource
        Task { await buildThumbnails(from: thumbSource) }
    }

    private func buildThumbnails(from source: UIImage) async {
        // Off the main actor — ten CIContext renders in a row is cheap at
        // this thumbnail size but still worth keeping off the UI thread.
        let rendered = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: PhotoFilter.allCases.map { ($0, $0.apply(to: source)) })
        }.value
        // Guard against a stale result landing after the user already
        // switched to a different base photo while this was still running.
        guard source === thumbnailSource else { return }
        thumbnails = rendered
    }

    /// Renders at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and trigger
    /// `refreshFromCurrentImage()`, resetting the picker on its own.
    private func apply() {
        guard selectedFilter != .none, let current = viewModel.resultImage ?? viewModel.sourceImage else { return }
        viewModel.resultImage = selectedFilter.apply(to: current)
    }

    private var emptyState: some View {
        PBEmptyState(icon: "camera.filters", message: "Choose a photo on the Upscale tab first.")
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

#Preview {
    let provider = UpscalerProvider()
    FiltersView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
