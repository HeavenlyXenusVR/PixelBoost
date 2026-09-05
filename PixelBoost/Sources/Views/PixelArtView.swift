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
    @State private var palette: PixelArtService.RetroPalette = .none
    @State private var autoPaletteColorCount: Double = 8
    @State private var saturation: Double = 1.0
    @State private var style: PixelArtService.Style = .balanced
    @State private var outline = false
    @State private var transparentBackground = false
    @State private var spriteExportEnabled = false
    @State private var spriteSize: Double = 32
    @State private var showGrid = false
    @State private var previewImage: UIImage?
    @State private var previewSource: UIImage?
    @State private var lastBase: UIImage?
    /// Real subject cutout (Vision's `VNGenerateForegroundInstanceMaskRequest`,
    /// same tech as the Cutout tab) for the live preview — computed once per
    /// `previewSource`, not on every slider tweak, since it's an actual
    /// segmentation pass, not a cheap per-pixel filter. `nil` while pending
    /// or if Vision found no distinct subject, in which case `updatePreview()`
    /// falls back to `PixelArtService`'s corner-color chroma-key so
    /// Transparent Background still does *something* rather than nothing.
    @State private var subjectCutout: UIImage?
    @State private var subjectCutoutBase: UIImage?
    @State private var isDetectingSubject = false
    @State private var isApplying = false

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

                                labeledSlider("Saturation", value: $saturation, range: 0.3...2.0, format: "%.1fx")

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Retro Palette")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                    Picker("Retro Palette", selection: $palette) {
                                        ForEach(PixelArtService.RetroPalette.allCases) { option in
                                            Text(option.rawValue).tag(option)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(PBColor.accent)
                                }

                                if palette == .auto {
                                    labeledSlider("Auto Palette Colors", value: $autoPaletteColorCount, range: 2...32, format: "%.0f")
                                }

                                if palette == .none {
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
                                } else {
                                    Text("A named palette replaces Limit Color Palette and Color Depth above with its own fixed set of colors.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(PBColor.inkDim)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Style")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                    Picker("Style", selection: $style) {
                                        ForEach(PixelArtService.Style.allCases) { option in
                                            Text(option.rawValue).tag(option)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                }

                                Toggle(isOn: $outline) {
                                    Text("Sprite Outline")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                }
                                .tint(PBColor.accent)

                                Toggle(isOn: $transparentBackground) {
                                    Text("Transparent Background")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                }
                                .tint(PBColor.accent)

                                if transparentBackground {
                                    if isDetectingSubject {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small)
                                            Text("Detecting subject…")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(PBColor.inkDim)
                                        }
                                    } else if subjectCutout == nil {
                                        Text("No distinct subject found — falling back to keying out the most common corner color instead.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(PBColor.inkDim)
                                    }
                                }

                                if !spriteExportEnabled {
                                    Toggle(isOn: $showGrid) {
                                        Text("Show Grid Lines")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(PBColor.ink)
                                    }
                                    .tint(PBColor.accent)
                                }

                                PBRowDivider()

                                Toggle(isOn: $spriteExportEnabled) {
                                    Text("Export as Sprite")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                }
                                .tint(PBColor.accent)

                                if spriteExportEnabled {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Sprite Size")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(PBColor.ink)
                                        Picker("Sprite Size", selection: $spriteSize) {
                                            Text("16px").tag(16.0)
                                            Text("32px").tag(32.0)
                                            Text("64px").tag(64.0)
                                            Text("128px").tag(128.0)
                                        }
                                        .pickerStyle(.segmented)
                                    }
                                    Text("Outputs the actual pixelated grid at this size — a game-ready sprite file, rather than a full-resolution photo with blocky squares. Block Size and Show Grid don't apply here.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(PBColor.inkDim)
                                }
                            }

                            Button {
                                Haptics.lightImpact()
                                Task { await apply() }
                            } label: {
                                if isApplying {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Apply", systemImage: "checkmark")
                                }
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
            .navigationTitle("Pixel Art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: blockSize, perform: { _ in updatePreview() })
            .onChange(of: posterize, perform: { _ in updatePreview() })
            .onChange(of: colorLevels, perform: { _ in updatePreview() })
            .onChange(of: colorDepth, perform: { _ in updatePreview() })
            .onChange(of: palette, perform: { _ in updatePreview() })
            .onChange(of: autoPaletteColorCount, perform: { _ in updatePreview() })
            .onChange(of: saturation, perform: { _ in updatePreview() })
            .onChange(of: style, perform: { _ in updatePreview() })
            .onChange(of: outline, perform: { _ in updatePreview() })
            .onChange(of: transparentBackground, perform: { _ in
                detectSubjectIfNeeded()
                updatePreview()
            })
            .onChange(of: spriteExportEnabled, perform: { _ in updatePreview() })
            .onChange(of: spriteSize, perform: { _ in updatePreview() })
            .onChange(of: showGrid, perform: { _ in updatePreview() })
            .onChange(of: viewModel.imageVersion, perform: { _ in refreshFromCurrentImage() })
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewSource = nil
            previewImage = nil
            subjectCutout = nil
            subjectCutoutBase = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewSource = Self.downscaled(current, maxDimension: 800)
        detectSubjectIfNeeded()
        updatePreview()
    }

    /// Runs Vision's real subject segmentation (`BackgroundRemovalService`,
    /// the same one the Cutout tab uses) once per `previewSource`, rather
    /// than on every slider tweak — a full detection pass is real work, not
    /// a cheap per-pixel filter like everything else this tab previews live.
    private func detectSubjectIfNeeded() {
        guard transparentBackground, let previewSource, previewSource !== subjectCutoutBase else { return }
        subjectCutoutBase = previewSource
        subjectCutout = nil
        isDetectingSubject = true
        Task {
            let cutout = try? await BackgroundRemovalService.removeBackground(from: previewSource)
            guard previewSource === subjectCutoutBase else { return } // superseded by a newer photo/refresh
            subjectCutout = cutout
            isDetectingSubject = false
            updatePreview()
        }
    }

    private func updatePreview() {
        guard let previewSource else { return }
        let base = (transparentBackground ? subjectCutout : nil) ?? previewSource
        previewImage = PixelArtService.apply(to: base, options: options(usingChromaKeyFallback: transparentBackground && subjectCutout == nil))
    }

    /// Renders at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and trigger
    /// `refreshFromCurrentImage()`. Runs its own full-resolution subject
    /// detection when Transparent Background is on, rather than reusing
    /// the (downscaled) preview's cutout — Apply should use the sharpest
    /// mask available, not whatever the live preview settled for at
    /// preview scale.
    private func apply() async {
        guard let current = viewModel.resultImage ?? viewModel.sourceImage, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        var base = current
        var useChromaKeyFallback = false
        if transparentBackground {
            if let cutout = try? await BackgroundRemovalService.removeBackground(from: current) {
                base = cutout
            } else {
                useChromaKeyFallback = true
            }
        }

        guard let result = PixelArtService.apply(to: base, options: options(usingChromaKeyFallback: useChromaKeyFallback)) else { return }
        viewModel.resultImage = result
    }

    /// `usingChromaKeyFallback` is true only when Transparent Background is
    /// on but Vision found no subject to cut around — `PixelArtService`'s
    /// own corner-color chroma-key then stands in, rather than Transparent
    /// Background silently doing nothing. When a real Vision cutout is
    /// already feeding `apply(to:options:)` its base image, this stays
    /// false: re-running the chroma-key against an image that's already
    /// been correctly keyed out would treat any dark/near-transparent-black
    /// pixels *inside* the subject (dark hair, a black jacket) as more
    /// "background" to remove.
    private func options(usingChromaKeyFallback: Bool) -> PixelArtService.Options {
        PixelArtService.Options(
            blockSize: Int(blockSize),
            colorLevels: posterize ? Int(colorLevels) : nil,
            colorDepth: colorDepth,
            palette: palette,
            autoPaletteColorCount: Int(autoPaletteColorCount),
            transparentBackground: usingChromaKeyFallback,
            spriteSize: spriteExportEnabled ? Int(spriteSize) : nil,
            saturation: saturation,
            style: style,
            outline: outline,
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
