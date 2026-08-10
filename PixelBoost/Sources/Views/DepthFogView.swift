import SwiftUI
import UniformTypeIdentifiers

/// Depth-based fog/haze using a companion depth (Z) pass EXR — see
/// `DepthFogService`. Genuinely different from every other tool here: it
/// needs a *second* image (the depth pass) picked separately from the
/// working photo, since a depth AOV isn't something Vision or a plain CNN
/// can derive from a flattened beauty-pass photo after the fact — it has
/// to come from the render engine itself.
struct DepthFogView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewSource: UIImage?
    @State private var previewImage: UIImage?
    @State private var depthMask: UIImage?
    @State private var isPresentingDepthImporter = false
    @State private var intensity: Double = 0.6
    @State private var fogColor = Color(red: 0.7, green: 0.75, blue: 0.8)
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
                                isPresentingDepthImporter = true
                            } label: {
                                Label(depthMask == nil ? "Import Depth Pass (EXR)" : "Replace Depth Pass", systemImage: "cube")
                            }
                            .buttonStyle(.pbGhost)

                            if let errorMessage {
                                Text(errorMessage)
                                    .pbFont(.caption)
                                    .foregroundStyle(PBColor.bad)
                                    .multilineTextAlignment(.center)
                            }

                            if depthMask != nil {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Fog Intensity")
                                        .pbFont(.eyebrow)
                                        .foregroundStyle(PBColor.inkFaint)
                                    Slider(value: $intensity, in: 0...1)
                                        .tint(PBColor.accent)
                                }

                                ColorPicker("Fog Color", selection: $fogColor, supportsOpacity: false)
                                    .pbFont(.body)
                                    .foregroundStyle(PBColor.ink)

                                Button {
                                    Haptics.lightImpact()
                                    apply()
                                } label: {
                                    Label("Apply Fog", systemImage: "cloud.fog")
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
            .navigationTitle("Depth Fog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(
                isPresented: $isPresentingDepthImporter,
                allowedContentTypes: [UTType(filenameExtension: "exr") ?? .data]
            ) { result in
                switch result {
                case .success(let url): loadDepthPass(from: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .onChange(of: intensity) { _, _ in updatePreview() }
            .onChange(of: fogColor) { _, _ in updatePreview() }
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
            depthMask = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewSource = current
        previewImage = current
        depthMask = nil
        errorMessage = nil
    }

    private func loadDepthPass(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access that file."
            return
        }
        Task {
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let mask = try await Task.detached(priority: .userInitiated) {
                    try EXRImportService.loadDepthImage(from: url)
                }.value
                depthMask = mask
                errorMessage = nil
                updatePreview()
                ActionLoggingService.log("depth_fog_import", detail: ["outcome": "success"])
            } catch {
                errorMessage = error.localizedDescription
                ActionLoggingService.log("depth_fog_import", detail: ["outcome": "failed", "error": error.localizedDescription])
            }
        }
    }

    private func updatePreview() {
        guard let previewSource, let depthMask else { return }
        let amount = intensity
        let color = UIColor(fogColor)
        isProcessingPreview = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DepthFogService.applyFog(previewSource, depthMask: depthMask, intensity: amount, fogColor: color)
            }.value
            previewImage = result
            isProcessingPreview = false
        }
    }

    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage, let depthMask else { return }
        let amount = intensity
        let color = UIColor(fogColor)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DepthFogService.applyFog(baseImage, depthMask: depthMask, intensity: amount, fogColor: color)
            }.value
            viewModel.resultImage = result
            Haptics.success()
            ActionLoggingService.log("depth_fog_apply", detail: ["intensity": amount])
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "cloud.fog", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    DepthFogView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
