import SwiftUI

/// Denoises 3D-render output (Blender/Cycles/Eevee, or any other path
/// tracer) using a converted Intel Open Image Denoise model — see
/// `RenderDenoiseService`. Distinct from Restore's denoise slider, which
/// targets sensor/ISO noise on real photos: a low-sample-count render's
/// noise (fireflies, blotchy variance) has a different character that a
/// generic photo denoiser isn't tuned for. The model itself has no
/// adjustable parameter, so the Strength slider here is a post-inference
/// mix back over the original (see `RenderDenoiseService.denoise`) rather
/// than a model setting — enough to back off a pass that's too aggressive
/// on a lightly-noisy render, which used to be all-or-nothing. Same
/// "chain onto whatever's current" pattern as every other tool.
struct RenderDenoiseView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewImage: UIImage?
    @State private var isApplying = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    /// Full strength by default — the behavior before this slider existed.
    @State private var strength: Double = 1.0

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

                            Text("Cleans up fireflies and sample-count noise from a 3D render (Blender Cycles/Eevee or any other path tracer) — a model trained specifically on renders, not the general photo denoiser Restore uses.")
                                .pbFont(.caption)
                                .foregroundStyle(PBColor.inkFaint)
                                .multilineTextAlignment(.center)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Strength")
                                        .pbFont(.eyebrow)
                                        .foregroundStyle(PBColor.inkFaint)
                                    Spacer()
                                    Text("\(Int(strength * 100))%")
                                        .pbFont(.caption)
                                        .foregroundStyle(PBColor.inkDim)
                                }
                                Slider(value: $strength, in: 0...1)
                                    .tint(PBColor.accent)
                                    .disabled(isApplying)
                                Text("The model always denoises at its own fixed intensity; this mixes that result back over the original, so a lower strength keeps more of the render's own texture.")
                                    .pbFont(.caption)
                                    .foregroundStyle(PBColor.inkFaint)
                            }

                            if isApplying {
                                VStack(spacing: 6) {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                        .tint(PBColor.accent)
                                    Text("Denoising… \(Int(progress * 100))%")
                                        .pbFont(.body)
                                        .foregroundStyle(PBColor.inkDim)
                                }
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .pbFont(.caption)
                                    .foregroundStyle(PBColor.bad)
                                    .multilineTextAlignment(.center)
                            }

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label(isApplying ? "Denoising…" : "Denoise", systemImage: "cube")
                            }
                            .buttonStyle(.pbGradient)
                            .disabled(isApplying)
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .pbScreen("Render Denoise")
            .pbRefresh(on: viewModel.imageVersion) { refreshFromCurrentImage() }
        }
    }

    /// Re-derives the working preview from whichever photo is current.
    /// Guarded by object identity (`!==`) so switching tabs back and forth
    /// without anything actually changing doesn't reset progress/error
    /// state for nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewImage = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewImage = current
        errorMessage = nil
        progress = 0
    }

    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage else { return }
        isApplying = true
        errorMessage = nil
        progress = 0
        let startedAt = Date()
        Task {
            do {
                let denoised = try await RenderDenoiseService.denoise(baseImage, strength: strength) { value in
                    Task { @MainActor in progress = value }
                }
                viewModel.resultImage = denoised
                Haptics.success()
                ActionLoggingService.log(
                    "render_denoise",
                    detail: [
                        "strength": strength,
                        "source_width": Int(baseImage.size.width),
                        "source_height": Int(baseImage.size.height),
                    ],
                    outcome: "success",
                    durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
                ActionLoggingService.log(
                    "render_denoise",
                    detail: ["strength": strength, "error": error.localizedDescription],
                    outcome: error is CancellationError ? "cancelled" : "failed",
                    durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
            }
            isApplying = false
        }
    }

    private var emptyState: some View {
        PBNoPhotoState(tab: .renderDenoise)
    }
}

#Preview {
    let provider = UpscalerProvider()
    RenderDenoiseView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
