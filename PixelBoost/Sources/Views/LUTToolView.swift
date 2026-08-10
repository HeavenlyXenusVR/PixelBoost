import SwiftUI
import UniformTypeIdentifiers

/// Applies an externally-authored `.cube` 3D LUT (DaVinci Resolve, Blender
/// LUT export add-ons, most render/grading pipelines can produce one) —
/// see `LUTService`. Distinct from the Filters tab's thirteen built-in
/// looks: a LUT is a look brought in from *outside* the app, not one of
/// PixelBoost's own presets.
struct LUTToolView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewSource: UIImage?
    @State private var previewImage: UIImage?
    @State private var lut: LUTService.LUT?
    @State private var lutName: String?
    @State private var isPresentingLUTImporter = false
    @State private var intensity: Double = 1.0
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
                                isPresentingLUTImporter = true
                            } label: {
                                Label(lutName ?? "Import .cube LUT", systemImage: "square.stack.3d.up")
                            }
                            .buttonStyle(.pbGhost)

                            if let errorMessage {
                                Text(errorMessage)
                                    .pbFont(.caption)
                                    .foregroundStyle(PBColor.bad)
                                    .multilineTextAlignment(.center)
                            }

                            if lut != nil {
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
                                    Label("Apply LUT", systemImage: "checkmark")
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
            .navigationTitle("LUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(
                isPresented: $isPresentingLUTImporter,
                allowedContentTypes: [UTType(filenameExtension: "cube") ?? .plainText]
            ) { result in
                switch result {
                case .success(let url): loadLUT(from: url)
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
            lut = nil
            lutName = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        let preview = Self.downscaled(current, maxDimension: 800)
        previewSource = preview
        previewImage = preview
        lut = nil
        lutName = nil
        errorMessage = nil
    }

    private func loadLUT(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try LUTService.parse(text)
            lut = parsed
            lutName = url.deletingPathExtension().lastPathComponent
            errorMessage = nil
            updatePreview()
            ActionLoggingService.log("lut_import", detail: ["outcome": "success", "dimension": parsed.dimension])
        } catch {
            errorMessage = error.localizedDescription
            ActionLoggingService.log("lut_import", detail: ["outcome": "failed", "error": error.localizedDescription])
        }
    }

    private func updatePreview() {
        guard let previewSource, let lut else { return }
        let amount = intensity
        isProcessingPreview = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LUTService.apply(lut, to: previewSource, intensity: amount)
            }.value
            previewImage = result
            isProcessingPreview = false
        }
    }

    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage, let lut else { return }
        let amount = intensity
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LUTService.apply(lut, to: baseImage, intensity: amount)
            }.value
            viewModel.resultImage = result
            Haptics.success()
            ActionLoggingService.log("lut_apply", detail: ["intensity": amount])
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "square.stack.3d.up", message: "Choose a photo on the Upscale tab first.")
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
    LUTToolView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
