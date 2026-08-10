import SwiftUI

/// "Object Removal" — paint over something to erase it; the marked area
/// gets filled in via `InpaintingService`'s diffusion fill (see that
/// file's doc comment for why it's not a generative model). Lives as its
/// own persistent tab (see `RootView`) — "Erase" commits the fill onto
/// the shared result and clears the brush strokes; no dismiss step
/// needed. Works best on small objects/blemishes over fairly uniform
/// backgrounds.
struct InpaintView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var baseImage: UIImage?
    @State private var lastBase: UIImage?
    @State private var strokes: [BrushStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var brushSize: CGFloat = 36
    @State private var containerSize: CGSize = .zero
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let baseImage {
                    VStack(spacing: 16) {
                        PBImageFrame {
                            GeometryReader { geo in
                                ZStack {
                                    Image(uiImage: baseImage)
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
                                .allowsHitTesting(!isProcessing)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in currentPoints.append(value.location) }
                                        .onEnded { _ in
                                            if !currentPoints.isEmpty {
                                                strokes.append(BrushStroke(points: currentPoints, brushSize: brushSize))
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
                            Slider(value: $brushSize, in: 12...80)
                                .tint(PBColor.accent)
                        }
                        .padding(.horizontal, 20)

                        HStack(spacing: 10) {
                            Button {
                                Haptics.lightImpact()
                                strokes.removeLast()
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.pbGhost)
                            .disabled(strokes.isEmpty)

                            Button {
                                Haptics.lightImpact()
                                strokes = []
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.pbGhost)
                            .disabled(strokes.isEmpty)
                        }
                        .padding(.horizontal, 20)

                        Button {
                            Haptics.lightImpact()
                            erase()
                        } label: {
                            Label("Erase", systemImage: "eraser")
                        }
                        .buttonStyle(.pbGradient)
                        .disabled(strokes.isEmpty || isProcessing)
                        .padding(.horizontal, 20)

                        if isProcessing {
                            HStack(spacing: 8) {
                                ProgressView().tint(PBColor.accent)
                                Text("Filling in the marked area…")
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

                        Spacer()
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Erase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    /// Re-derives the canvas base from whichever photo is current, and
    /// clears in-progress strokes (positioned against the *previous*
    /// base; after a successful `erase()` they're already baked into the
    /// new one). Guarded by object identity (`!==`) so switching tabs
    /// back and forth without anything actually changing doesn't wipe an
    /// in-progress mask for nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            baseImage = nil
            strokes = []
            currentPoints = []
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        baseImage = current
        strokes = []
        currentPoints = []
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
            with: .color(.red.opacity(0.45)),
            style: StrokeStyle(lineWidth: brushSize, lineCap: .round, lineJoin: .round)
        )
    }

    /// Runs the fill and writes back to the shared result — which will
    /// itself bump `imageVersion` and trigger `refreshFromCurrentImage()`,
    /// clearing the brush strokes on its own.
    private func erase() {
        guard let baseImage, containerSize.width > 0, containerSize.height > 0, !strokes.isEmpty else { return }
        isProcessing = true
        errorMessage = nil
        let mask = BrushMask.rasterize(strokes, canvasSize: containerSize, pixelSize: baseImage.size)

        Task {
            do {
                let result = try await InpaintingService.fill(baseImage, maskImage: mask)
                Haptics.success()
                viewModel.resultImage = result
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
            isProcessing = false
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "eraser", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    InpaintView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
