import SwiftUI

/// One-tap automatic exposure/color correction. Lives as its own
/// persistent tab (see `RootView`) like every other tool — analyze once,
/// preview large, "Apply" bakes it onto the shared result. No sliders:
/// the whole point is it's the one-tap fix competitors ship (Snapseed's
/// "Tune Image" auto, Photoshop Express's "Auto Enhance").
struct AutoEnhanceView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var baseImage: UIImage?
    @State private var lastBase: UIImage?
    @State private var enhancedPreview: UIImage?
    @State private var isAnalyzing = false

    var body: some View {
        NavigationStack {
            Group {
                if let baseImage {
                    ScrollView {
                        VStack(spacing: 20) {
                            Image(uiImage: enhancedPreview ?? baseImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 340)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            Text(enhancedPreview == nil
                                 ? "Automatically balances exposure, color, and contrast — the same auto-fix analysis Snapseed and Photoshop Express use."
                                 : "Preview of the automatic fix.")
                                .font(.system(size: 13))
                                .foregroundStyle(PBColor.inkDim)
                                .multilineTextAlignment(.center)

                            if enhancedPreview == nil {
                                Button {
                                    Haptics.lightImpact()
                                    analyze()
                                } label: {
                                    Label(isAnalyzing ? "Analyzing…" : "Auto Enhance", systemImage: "wand.and.rays")
                                }
                                .buttonStyle(.pbGradient)
                                .disabled(isAnalyzing)
                            } else {
                                HStack(spacing: 10) {
                                    Button {
                                        Haptics.lightImpact()
                                        enhancedPreview = nil
                                    } label: {
                                        Label("Discard", systemImage: "xmark")
                                    }
                                    .buttonStyle(.pbGhost)

                                    Button {
                                        Haptics.lightImpact()
                                        apply()
                                    } label: {
                                        Label("Apply", systemImage: "checkmark")
                                    }
                                    .buttonStyle(.pbGradient)
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Enhance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    /// Re-derives from whichever photo is current. Guarded by object
    /// identity (`!==`) so switching tabs back and forth without anything
    /// actually changing doesn't discard an unapplied preview for nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            baseImage = nil
            enhancedPreview = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        baseImage = current
        enhancedPreview = nil
    }

    /// Runs against a downscaled copy for a fast preview — full-resolution
    /// analysis only happens once, in `apply()`.
    private func analyze() {
        guard let baseImage else { return }
        isAnalyzing = true
        let preview = Self.downscaled(baseImage, maxDimension: 900)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AutoEnhanceService.enhance(preview)
            }.value
            enhancedPreview = result
            isAnalyzing = false
        }
    }

    /// Re-runs at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and trigger
    /// `refreshFromCurrentImage()`, clearing the preview on its own.
    private func apply() {
        guard let baseImage else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AutoEnhanceService.enhance(baseImage)
            }.value
            viewModel.resultImage = result
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(PBColor.inkFaint)
            Text("Choose a photo on the Upscale tab first.")
                .font(.system(size: 13))
                .foregroundStyle(PBColor.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    AutoEnhanceView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
