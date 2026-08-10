import SwiftUI

/// Makes a texture tileable — offsets the image by half its size (wrapping
/// the edges around, so any edge mismatch lands in the forgiving middle of
/// the canvas instead of right at the tile boundary) then blends a
/// blurred copy back in along the new seam lines. See
/// `SeamlessTextureService`. Live preview on the heal-width slider, same
/// "Apply" pattern as every other tool once you're happy with it.
struct SeamlessTextureView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var wrappedSource: UIImage?
    @State private var previewImage: UIImage?
    @State private var healWidth: Double = 0.08
    @State private var isProcessingPreview = false

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    ScrollView {
                        VStack(spacing: 24) {
                            PBImageFrame {
                                ZStack {
                                    Image(uiImage: previewImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 340)
                                    if isProcessingPreview {
                                        ProgressView().tint(PBColor.accent)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Seam Blend Width")
                                    .pbFont(.eyebrow)
                                    .foregroundStyle(PBColor.inkFaint)
                                Slider(value: $healWidth, in: 0.02...0.25)
                                    .tint(PBColor.accent)
                                Text("Offsets the texture by half its size, wrapping the edges around, then blends the new seam lines. Wider blend hides a bigger mismatch but softens more of the middle.")
                                    .pbFont(.caption)
                                    .foregroundStyle(PBColor.inkFaint)
                            }

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label("Make Seamless", systemImage: "square.grid.3x3")
                            }
                            .buttonStyle(.pbGradient)
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Seamless Texture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: healWidth) { _, _ in updatePreview() }
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            wrappedSource = nil
            previewImage = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        let preview = Self.downscaled(current, maxDimension: 800)
        let wrapped = SeamlessTextureService.wrapOffset(preview)
        wrappedSource = wrapped
        updatePreview()
    }

    /// Re-heals the already-wrapped preview on every slider change —
    /// `wrapOffset` itself doesn't depend on `healWidth`, so it only needs
    /// to run once per source image, not once per slider tick.
    private func updatePreview() {
        guard let wrappedSource else { return }
        let width = healWidth
        isProcessingPreview = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SeamlessTextureService.healSeamCross(wrappedSource, healWidth: width)
            }.value
            previewImage = result
            isProcessingPreview = false
        }
    }

    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage else { return }
        let width = healWidth
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SeamlessTextureService.makeSeamless(baseImage, healWidth: width)
            }.value
            viewModel.resultImage = result
            Haptics.success()
            ActionLoggingService.log("seamless_texture", detail: ["heal_width": width])
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "square.grid.3x3", message: "Choose a photo on the Upscale tab first.")
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
    SeamlessTextureView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
