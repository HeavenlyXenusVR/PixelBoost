import SwiftUI

/// Two "old/rough photo" fixes in one tab: a denoise slider
/// (`CINoiseReduction`) and a "Restore Faces" toggle — a classical
/// sharpen/detail boost applied only over Vision-detected face regions,
/// not a trained restoration model (see `RestoreService`). Same persistent
/// tab / Apply-not-Done pattern as every other editing tab.
struct RestoreView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewSource: UIImage?
    @State private var previewImage: UIImage?
    @State private var denoiseAmount: Double = 0
    @State private var faceRestoreEnabled = false
    @State private var noFacesDetected = false
    @State private var isProcessingPreview = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    ScrollView {
                        VStack(spacing: 24) {
                            ZStack {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 340)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                if isProcessingPreview {
                                    ProgressView().tint(PBColor.accent)
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Denoise")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(PBColor.inkFaint)
                                Slider(value: $denoiseAmount, in: 0...1)
                                    .tint(PBColor.accent)
                                Text("Smooths grain and sensor noise while trying to hold onto fine detail.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(PBColor.inkFaint)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: $faceRestoreEnabled) {
                                    Text("Restore Faces")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                }
                                .tint(PBColor.accent)
                                Text("Sharpens detail just around detected faces — a classical boost, not a generative model.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(PBColor.inkFaint)
                                if noFacesDetected {
                                    Text("No faces detected in this photo.")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(PBColor.warn)
                                }
                            }

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label(isApplying ? "Applying…" : "Apply", systemImage: "checkmark")
                            }
                            .buttonStyle(.pbGradient)
                            .disabled(isApplying || (denoiseAmount == 0 && !faceRestoreEnabled))
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: denoiseAmount) { _, _ in updatePreview() }
            .onChange(of: faceRestoreEnabled) { _, _ in updatePreview() }
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
            resetControls()
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        let preview = Self.downscaled(current, maxDimension: 800)
        previewSource = preview
        previewImage = preview
        resetControls()
    }

    private func resetControls() {
        denoiseAmount = 0
        faceRestoreEnabled = false
        noFacesDetected = false
    }

    /// Runs against a downscaled copy for a fast preview — full-resolution
    /// processing only happens once, in `apply()`. Denoise is cheap enough
    /// to run inline; face restoration involves a Vision request, so it's
    /// flagged with `isProcessingPreview` while it's in flight.
    private func updatePreview() {
        guard let previewSource else { return }
        let amount = denoiseAmount
        let wantsFaceRestore = faceRestoreEnabled
        isProcessingPreview = true
        Task {
            var result = amount > 0
                ? await Task.detached(priority: .userInitiated) { RestoreService.denoise(previewSource, amount: amount) }.value
                : previewSource

            if wantsFaceRestore {
                if let restored = await RestoreService.restoreFaces(result) {
                    result = restored
                    noFacesDetected = false
                } else {
                    noFacesDetected = true
                    faceRestoreEnabled = false
                }
            }

            previewImage = result
            isProcessingPreview = false
        }
    }

    /// Re-runs at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and trigger
    /// `refreshFromCurrentImage()`, resetting the controls on its own.
    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage else { return }
        guard denoiseAmount > 0 || faceRestoreEnabled else { return }
        let amount = denoiseAmount
        let wantsFaceRestore = faceRestoreEnabled
        isApplying = true
        Task {
            var result = amount > 0
                ? await Task.detached(priority: .userInitiated) { RestoreService.denoise(baseImage, amount: amount) }.value
                : baseImage

            if wantsFaceRestore, let restored = await RestoreService.restoreFaces(result) {
                result = restored
            }

            viewModel.resultImage = result
            isApplying = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bandage")
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
    RestoreView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
