import SwiftUI

/// Converts the current photo into a retro pixel-art look — block size,
/// optional palette posterizing, optional grid lines, live preview. Same
/// persistent-tab/Apply-bakes-and-resets shape as every other editing tab
/// (see `AdjustmentsView`'s doc comment); no Cancel/Done step.
struct PixelArtView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var blockSize: Double = 10
    @State private var posterize = true
    @State private var colorLevels: Double = 6
    @State private var colorDepth: PixelArtService.ColorDepth = .bit32
    @State private var showGrid = false
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
                                    .interpolation(.none)
                                    .scaledToFit()
                                    .frame(maxHeight: 340)
                            }

                            VStack(spacing: 18) {
                                Text("Pixel Art")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(PBColor.inkFaint)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                labeledSlider("Block Size", value: $blockSize, range: 3...32, format: "%.0fpx")

                                Toggle(isOn: $posterize) {
                                    Text("Limit Color Palette")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                }
                                .tint(PBColor.accent)

                                if posterize {
                                    labeledSlider("Palette Levels", value: $colorLevels, range: 2...16, format: "%.0f")
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Color Depth")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                    Picker("Color Depth", selection: $colorDepth) {
                                        ForEach(PixelArtService.ColorDepth.allCases) { depth in
                                            Text(depth.rawValue).tag(depth)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                }

                                Toggle(isOn: $showGrid) {
                                    Text("Show Grid Lines")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                }
                                .tint(PBColor.accent)
                            }

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label("Apply", systemImage: "checkmark")
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
            .navigationTitle("Pixel Art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: blockSize) { _, _ in updatePreview() }
            .onChange(of: posterize) { _, _ in updatePreview() }
            .onChange(of: colorLevels) { _, _ in updatePreview() }
            .onChange(of: colorDepth) { _, _ in updatePreview() }
            .onChange(of: showGrid) { _, _ in updatePreview() }
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
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewSource = Self.downscaled(current, maxDimension: 800)
        updatePreview()
    }

    private func updatePreview() {
        guard let previewSource else { return }
        previewImage = PixelArtService.apply(to: previewSource, options: currentOptions)
    }

    /// Renders at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and trigger
    /// `refreshFromCurrentImage()`.
    private func apply() {
        guard let current = viewModel.resultImage ?? viewModel.sourceImage else { return }
        guard let result = PixelArtService.apply(to: current, options: currentOptions) else { return }
        viewModel.resultImage = result
    }

    private var currentOptions: PixelArtService.Options {
        PixelArtService.Options(
            blockSize: Int(blockSize),
            colorLevels: posterize ? Int(colorLevels) : nil,
            colorDepth: colorDepth,
            showGrid: showGrid
        )
    }

    private func labeledSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PBColor.inkDim)
            }
            Slider(value: value, in: range)
                .tint(PBColor.accent)
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "square.grid.3x3.fill", message: "Choose a photo on the Upscale tab first.")
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
    PixelArtView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
