import SwiftUI

/// Cutout's own tab. Unlike the other five tools there's nothing to
/// adjust interactively (no sliders, crop handles, brush) — background
/// removal is a single unattended action — so this is a lighter screen:
/// a preview of the current photo, a one-line explanation, and a button.
/// Writes straight to `viewModel.resultImage`, same as every other tool.
struct CutoutTabView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var selectedFill: BackgroundFill?
    @State private var fillPreview: UIImage?
    @State private var isProcessingFill = false

    private var currentImage: UIImage? {
        viewModel.resultImage ?? viewModel.sourceImage
    }

    private var isAnyToolRunning: Bool {
        viewModel.isUpscaling || viewModel.isComparing || viewModel.isRemovingBackground
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let currentImage {
                        PBImageFrame {
                            Image(uiImage: fillPreview ?? currentImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 340)
                        }

                        Text("Cuts the main subject out of your photo with a transparent background, using on-device subject detection — the same technology behind Photos' \"Lift Subject.\"")
                            .pbFont(.body)
                            .foregroundStyle(PBColor.inkDim)
                            .multilineTextAlignment(.center)

                        Button {
                            Haptics.lightImpact()
                            viewModel.removeBackground()
                        } label: {
                            Label("Remove Background", systemImage: "scissors")
                        }
                        .buttonStyle(.pbGradient)
                        .disabled(isAnyToolRunning)

                        if viewModel.isRemovingBackground {
                            HStack(spacing: 8) {
                                ProgressView().tint(PBColor.accent)
                                Text("Finding the subject to cut out…")
                                    .pbFont(.body)
                                    .foregroundStyle(PBColor.inkDim)
                            }
                        }

                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .pbFont(.caption)
                                .foregroundStyle(PBColor.bad)
                                .multilineTextAlignment(.center)
                        }

                        if currentImage.hasAlphaChannel {
                            backgroundReplaceSection
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(20)
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Cutout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in
                selectedFill = nil
                fillPreview = nil
            }
        }
    }

    /// Only shown once the current image actually has transparency (a
    /// Cutout result) — a fill behind an opaque photo would just be
    /// invisible. Picking a swatch computes a downscaled preview; Apply
    /// bakes it at full resolution onto the shared result, same as every
    /// other tool's Apply button.
    private var backgroundReplaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(PBColor.inkFaint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(BackgroundFill.allCases) { fill in
                        fillSwatch(fill)
                    }
                }
                .padding(.horizontal, 2)
            }

            if selectedFill != nil {
                HStack(spacing: 10) {
                    Button {
                        Haptics.lightImpact()
                        selectedFill = nil
                        fillPreview = nil
                    } label: {
                        Label("Discard", systemImage: "xmark")
                    }
                    .buttonStyle(.pbGhost)

                    Button {
                        Haptics.lightImpact()
                        applyFill()
                    } label: {
                        Label(isProcessingFill ? "Applying…" : "Apply", systemImage: "checkmark")
                    }
                    .buttonStyle(.pbGradient)
                    .disabled(isProcessingFill)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fillSwatch(_ fill: BackgroundFill) -> some View {
        let isSelected = selectedFill == fill
        let colors = fill.swatchColors
        return Button {
            selectFill(fill)
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(colors.count > 1
                        ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(colors[0]))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().strokeBorder(isSelected ? PBColor.accent : PBColor.line, lineWidth: isSelected ? 2.5 : 1)
                    )
                Text(fill.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? PBColor.accent : PBColor.inkDim)
            }
        }
        .buttonStyle(.plain)
    }

    /// Runs against a downscaled copy for a fast preview — full-resolution
    /// compositing only happens once, in `applyFill()`.
    private func selectFill(_ fill: BackgroundFill) {
        Haptics.lightImpact()
        selectedFill = fill
        guard let currentImage else { return }
        let previewSubject = Self.downscaled(currentImage, maxDimension: 800)
        let previewOriginal = viewModel.sourceImage.map { Self.downscaled($0, maxDimension: 800) }
        isProcessingFill = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BackgroundReplaceService.apply(fill, behind: previewSubject, original: previewOriginal)
            }.value
            fillPreview = result
            isProcessingFill = false
        }
    }

    /// Re-runs at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and clear the fill preview
    /// via the `onChange` above.
    private func applyFill() {
        guard let selectedFill, let currentImage else { return }
        let originalImage = viewModel.sourceImage
        isProcessingFill = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BackgroundReplaceService.apply(selectedFill, behind: currentImage, original: originalImage)
            }.value
            viewModel.resultImage = result
            isProcessingFill = false
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "scissors", message: "Choose a photo on the Upscale tab first.")
            .frame(height: 220)
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
    CutoutTabView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
