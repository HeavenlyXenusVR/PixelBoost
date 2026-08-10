import SwiftUI
import UniformTypeIdentifiers

/// Multiplies a companion Ambient Occlusion pass EXR onto the working
/// photo — see `AOBlendService`. Same shape as `DepthFogView` (a second,
/// separately-imported AOV rather than something derivable from the
/// flattened beauty pass alone), simpler compositing (a straight multiply,
/// no color to pick).
struct AOBlendView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewSource: UIImage?
    @State private var previewImage: UIImage?
    @State private var aoMask: UIImage?
    @State private var isPresentingAOImporter = false
    @State private var intensity: Double = 0.8
    @State private var isProcessingPreview = false
    @State private var errorMessage: String?

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

                            Button {
                                Haptics.lightImpact()
                                isPresentingAOImporter = true
                            } label: {
                                Label(aoMask == nil ? "Import AO Pass (EXR)" : "Replace AO Pass", systemImage: "cube")
                            }
                            .buttonStyle(.pbGhost)

                            if let errorMessage {
                                Text(errorMessage)
                                    .pbFont(.caption)
                                    .foregroundStyle(PBColor.bad)
                                    .multilineTextAlignment(.center)
                            }

                            if aoMask != nil {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Intensity")
                                        .pbFont(.eyebrow)
                                        .foregroundStyle(PBColor.inkFaint)
                                    Slider(value: $intensity, in: 0...1)
                                        .tint(PBColor.accent)
                                }

                                Button {
                                    Haptics.lightImpact()
                                    apply()
                                } label: {
                                    Label("Apply AO", systemImage: "checkmark")
                                }
                                .buttonStyle(.pbGradient)
                            }
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("AO Blend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(
                isPresented: $isPresentingAOImporter,
                allowedContentTypes: [UTType(filenameExtension: "exr") ?? .data]
            ) { result in
                switch result {
                case .success(let url): loadAOPass(from: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .onChange(of: intensity) { _, _ in updatePreview() }
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewSource = nil
            previewImage = nil
            aoMask = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewSource = current
        previewImage = current
        aoMask = nil
        errorMessage = nil
    }

    private func loadAOPass(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access that file."
            return
        }
        Task {
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let mask = try await Task.detached(priority: .userInitiated) {
                    try EXRImportService.loadMaskImage(from: url)
                }.value
                aoMask = mask
                errorMessage = nil
                updatePreview()
                ActionLoggingService.log("ao_blend_import", detail: ["outcome": "success"])
            } catch {
                errorMessage = error.localizedDescription
                ActionLoggingService.log("ao_blend_import", detail: ["outcome": "failed", "error": error.localizedDescription])
            }
        }
    }

    private func updatePreview() {
        guard let previewSource, let aoMask else { return }
        let amount = intensity
        isProcessingPreview = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AOBlendService.applyAO(previewSource, aoMask: aoMask, intensity: amount)
            }.value
            previewImage = result
            isProcessingPreview = false
        }
    }

    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage, let aoMask else { return }
        let amount = intensity
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AOBlendService.applyAO(baseImage, aoMask: aoMask, intensity: amount)
            }.value
            viewModel.resultImage = result
            Haptics.success()
            ActionLoggingService.log("ao_blend_apply", detail: ["intensity": amount])
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "cube", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    AOBlendView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
