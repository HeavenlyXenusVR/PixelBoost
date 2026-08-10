import SwiftUI

/// Brightness/contrast/saturation/exposure sliders with a live preview.
/// Lives as its own persistent tab (see `RootView`), not a modal — there's
/// no Cancel/Done. "Apply" bakes the current sliders onto the shared
/// result and resets them to neutral; you're free to keep adjusting or
/// switch to another tab whenever, no dismiss step needed.
struct AdjustmentsView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var adjustments = PhotoAdjustments()
    @State private var previewImage: UIImage?
    @State private var previewSource: UIImage?
    @State private var lastBase: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    ScrollView {
                        VStack(spacing: 24) {
                            PBImageFrame {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 340)
                            }

                            VStack(spacing: 18) {
                                HStack {
                                    Text("Adjustments")
                                        .font(.system(size: 12, weight: .bold))
                                        .tracking(0.4)
                                        .foregroundStyle(PBColor.inkFaint)
                                    Spacer()
                                    Button("Reset") { adjustments = .identity }
                                        .font(.system(size: 13, weight: .semibold))
                                        .disabled(adjustments.isIdentity)
                                }
                                adjustmentSlider("Brightness", value: $adjustments.brightness, range: -0.5...0.5)
                                adjustmentSlider("Contrast", value: $adjustments.contrast, range: 0.5...1.5)
                                adjustmentSlider("Saturation", value: $adjustments.saturation, range: 0...2)
                                adjustmentSlider("Exposure", value: $adjustments.exposure, range: -1.5...1.5)
                                adjustmentSlider("Vignette", value: $adjustments.vignetteIntensity, range: 0...1)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Curve")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(PBColor.inkFaint)
                                CurveEditorView(points: $adjustments.curvePoints)
                                Text("Drag a point up or down to reshape tones at that brightness level.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(PBColor.inkFaint)
                            }

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label("Apply", systemImage: "checkmark")
                            }
                            .buttonStyle(.pbGradient)
                            .disabled(adjustments.isIdentity)
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: adjustments) { _, newValue in
                guard let previewSource else { return }
                previewImage = newValue.apply(to: previewSource)
            }
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    /// Re-derives the working preview from whichever photo is current.
    /// Guarded by object identity (`!==`) so switching tabs back and forth
    /// without anything actually changing doesn't re-downscale for nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewSource = nil
            previewImage = nil
            adjustments = .identity
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        let preview = Self.downscaled(current, maxDimension: 800)
        previewSource = preview
        previewImage = preview
        adjustments = .identity
    }

    /// Renders at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and trigger
    /// `refreshFromCurrentImage()`, resetting the sliders on its own.
    private func apply() {
        guard let current = viewModel.resultImage ?? viewModel.sourceImage, !adjustments.isIdentity else { return }
        viewModel.resultImage = adjustments.apply(to: current)
    }

    private func adjustmentSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PBColor.ink)
            Slider(value: value, in: range)
                .tint(PBColor.accent)
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "slider.horizontal.3", message: "Choose a photo on the Upscale tab first.")
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
    AdjustmentsView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
