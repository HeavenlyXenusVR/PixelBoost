import SwiftUI

/// Denoises 3D-render output (Blender/Cycles/Eevee, or any other path
/// tracer) using a converted Intel Open Image Denoise model — see
/// `RenderDenoiseService`. Distinct from Restore's denoise slider, which
/// targets sensor/ISO noise on real photos: a low-sample-count render's
/// noise (fireflies, blotchy variance) has a different character that a
/// generic photo denoiser isn't tuned for. Fixed-strength (the model has no
/// adjustable parameter, unlike Restore's slider), so this is a single
/// Apply action, same "chain onto whatever's current" pattern as every
/// other tool.
struct RenderDenoiseView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewImage: UIImage?
    @State private var isApplying = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

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
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Render Denoise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
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
        Task {
            do {
                let denoised = try await RenderDenoiseService.denoise(baseImage) { value in
                    Task { @MainActor in progress = value }
                }
                viewModel.resultImage = denoised
                Haptics.success()
                ActionLoggingService.log("render_denoise", detail: ["outcome": "success"])
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
                ActionLoggingService.log("render_denoise", detail: ["outcome": "failed", "error": error.localizedDescription])
            }
            isApplying = false
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "cube", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    RenderDenoiseView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
