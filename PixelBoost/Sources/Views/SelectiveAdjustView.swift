import SwiftUI

/// Selective (local) adjustments — paint a region, then brightness/
/// contrast/saturation/exposure/curve apply only inside it, blended back
/// over the untouched original everywhere else
/// (`SelectiveAdjustmentService`). Combines three already-proven pieces:
/// the brush-painting gesture from Object Removal (`BrushStroke`/
/// `BrushMask`), `PhotoAdjustments`' filter chain from the global Adjust
/// tab, and the mask-compositing approach `BackgroundRemovalService`/
/// `InpaintingService` both already use.
struct SelectiveAdjustView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var baseImage: UIImage?
    @State private var lastBase: UIImage?
    @State private var previewSource: UIImage?
    @State private var previewImage: UIImage?
    @State private var strokes: [BrushStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var brushSize: CGFloat = 60
    @State private var adjustments = PhotoAdjustments()
    @State private var containerSize: CGSize = .zero
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Group {
                if let baseImage {
                    ScrollView {
                        VStack(spacing: 16) {
                            PBImageFrame {
                                GeometryReader { geo in
                                    ZStack {
                                        Image(uiImage: previewImage ?? baseImage)
                                            .resizable()
                                            .frame(width: geo.size.width, height: geo.size.height)

                                        Canvas { context, _ in
                                            for stroke in strokes {
                                                drawStroke(stroke.points, brushSize: stroke.brushSize, in: &context)
                                            }
                                            if !currentPoints.isEmpty {
                                                drawStroke(currentPoints, brushSize: brushSize, in: &context)
                                            }
                                        }
                                        .allowsHitTesting(false)
                                    }
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in currentPoints.append(value.location) }
                                            .onEnded { _ in
                                                if !currentPoints.isEmpty {
                                                    strokes.append(BrushStroke(points: currentPoints, brushSize: brushSize))
                                                    updatePreview()
                                                }
                                                currentPoints = []
                                            }
                                    )
                                    .onAppear { containerSize = geo.size }
                                    .onChange(of: geo.size) { _, newSize in containerSize = newSize }
                                }
                            }
                            .aspectRatio(baseImage.size, contentMode: .fit)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Brush Size")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(PBColor.ink)
                                Slider(value: $brushSize, in: 20...120)
                                    .tint(PBColor.accent)
                            }
                            .padding(.horizontal, 20)

                            HStack(spacing: 10) {
                                Button {
                                    Haptics.lightImpact()
                                    strokes.removeLast()
                                    updatePreview()
                                } label: {
                                    Label("Undo", systemImage: "arrow.uturn.backward")
                                }
                                .buttonStyle(.pbGhost)
                                .disabled(strokes.isEmpty)

                                Button {
                                    Haptics.lightImpact()
                                    strokes = []
                                    updatePreview()
                                } label: {
                                    Label("Clear", systemImage: "xmark.circle")
                                }
                                .buttonStyle(.pbGhost)
                                .disabled(strokes.isEmpty)
                            }
                            .padding(.horizontal, 20)

                            VStack(spacing: 18) {
                                HStack {
                                    Text("Adjustments Inside the Painted Area")
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
                            }
                            .padding(.horizontal, 20)

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label(isApplying ? "Applying…" : "Apply", systemImage: "checkmark")
                            }
                            .buttonStyle(.pbGradient)
                            .disabled(strokes.isEmpty || adjustments.isIdentity || isApplying)
                            .padding(.horizontal, 20)
                        }
                        .padding(.bottom, 20)
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Selective")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: adjustments) { _, _ in updatePreview() }
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    /// Re-derives from whichever photo is current. Guarded by object
    /// identity (`!==`) so switching tabs back and forth without anything
    /// actually changing doesn't wipe an in-progress mask/sliders for
    /// nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            baseImage = nil
            previewSource = nil
            previewImage = nil
            strokes = []
            adjustments = .identity
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        baseImage = current
        previewSource = Self.downscaled(current, maxDimension: 800)
        previewImage = nil
        strokes = []
        adjustments = .identity
    }

    /// Recomputes the live preview against the downscaled copy — cheap
    /// enough for the main thread, the same tradeoff `AdjustmentsView`'s
    /// live preview already makes. Only called after a completed stroke
    /// or a slider change, not on every paint frame, so dragging the
    /// brush itself stays smooth.
    private func updatePreview() {
        guard let previewSource, containerSize.width > 0 else { return }
        guard !strokes.isEmpty, !adjustments.isIdentity else {
            previewImage = nil
            return
        }
        let mask = BrushMask.rasterize(strokes, canvasSize: containerSize, pixelSize: previewSource.size)
        previewImage = SelectiveAdjustmentService.apply(adjustments, to: previewSource, maskedBy: mask)
    }

    private func drawStroke(_ points: [CGPoint], brushSize: CGFloat, in context: inout GraphicsContext) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(
            path,
            with: .color(.white.opacity(0.35)),
            style: StrokeStyle(lineWidth: brushSize, lineCap: .round, lineJoin: .round)
        )
    }

    /// Bakes the mask + adjustments at full resolution and writes back to
    /// the shared result — which will itself bump `imageVersion` and
    /// trigger `refreshFromCurrentImage()`, clearing strokes/sliders on
    /// its own.
    private func apply() {
        guard let baseImage, containerSize.width > 0, !strokes.isEmpty, !adjustments.isIdentity else { return }
        isApplying = true
        let mask = BrushMask.rasterize(strokes, canvasSize: containerSize, pixelSize: baseImage.size)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SelectiveAdjustmentService.apply(adjustments, to: baseImage, maskedBy: mask)
            }.value
            viewModel.resultImage = result
            isApplying = false
        }
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
        PBEmptyState(icon: "paintbrush.pointed", message: "Choose a photo on the Upscale tab first.")
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
    SelectiveAdjustView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
