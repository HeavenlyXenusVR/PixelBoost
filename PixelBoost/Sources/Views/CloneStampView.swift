import SwiftUI

/// "Clone Stamp" — tap a source point, then paint elsewhere to copy pixels
/// from a fixed offset relative to that source point (the offset is set
/// once, from the source point and the very first point painted after it,
/// then stays constant for every stroke after that — standard clone-stamp
/// behavior, matching Photoshop's alt-click-then-paint gesture). Its own
/// persistent tab (see `RootView`) since the tap-then-paint interaction is
/// genuinely different from every other tool's single-gesture painting.
/// "Apply" bakes the clone onto the shared result and clears strokes/source;
/// no dismiss step needed.
struct CloneStampView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var baseImage: UIImage?
    @State private var lastBase: UIImage?
    @State private var sourcePoint: CGPoint?
    @State private var offset: CGPoint?
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
                                    if let sourcePoint {
                                        drawSourceMarker(at: sourcePoint, in: &context)
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                            .contentShape(Rectangle())
                            .allowsHitTesting(!isProcessing)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard sourcePoint != nil else { return }
                                        currentPoints.append(value.location)
                                    }
                                    .onEnded { value in
                                        guard sourcePoint != nil else {
                                            sourcePoint = value.location
                                            Haptics.lightImpact()
                                            return
                                        }
                                        if !currentPoints.isEmpty {
                                            if offset == nil, let first = currentPoints.first, let sourcePoint {
                                                offset = CGPoint(x: sourcePoint.x - first.x, y: sourcePoint.y - first.y)
                                            }
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

                        Text(instructions)
                            .pbFont(.body)
                            .foregroundStyle(PBColor.inkDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)

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
                                sourcePoint = nil
                                offset = nil
                            } label: {
                                Label(sourcePoint == nil ? "Set Source" : "Change Source", systemImage: "scope")
                            }
                            .buttonStyle(.pbGhost)

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
                                offset = nil
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.pbGhost)
                            .disabled(strokes.isEmpty)
                        }
                        .padding(.horizontal, 20)

                        Button {
                            Haptics.lightImpact()
                            apply()
                        } label: {
                            Label(isProcessing ? "Applying…" : "Apply", systemImage: "stamp")
                        }
                        .buttonStyle(.pbGradient)
                        .disabled(strokes.isEmpty || offset == nil || isProcessing)
                        .padding(.horizontal, 20)

                        if isProcessing {
                            HStack(spacing: 8) {
                                ProgressView().tint(PBColor.accent)
                                Text("Cloning the marked area…")
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
            .navigationTitle("Clone Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private var instructions: String {
        if sourcePoint == nil {
            return "Tap the area you want to copy from."
        } else if offset == nil {
            return "Now paint where you want to clone to."
        } else {
            return "Keep painting — the same offset is reused for every stroke. Tap Change Source to pick a new area."
        }
    }

    /// Re-derives the canvas base from whichever photo is current, and
    /// clears in-progress strokes/source (positioned against the
    /// *previous* base; after a successful `apply()` they're already baked
    /// into the new one). Guarded by object identity (`!==`) so switching
    /// tabs back and forth without anything actually changing doesn't wipe
    /// in-progress work for nothing.
    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            baseImage = nil
            strokes = []
            currentPoints = []
            sourcePoint = nil
            offset = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        baseImage = current
        strokes = []
        currentPoints = []
        sourcePoint = nil
        offset = nil
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
            with: .color(PBColor.accent.opacity(0.45)),
            style: StrokeStyle(lineWidth: brushSize, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawSourceMarker(at point: CGPoint, in context: inout GraphicsContext) {
        let radius: CGFloat = 12
        var circle = Path()
        circle.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.stroke(circle, with: .color(.white), style: StrokeStyle(lineWidth: 2))

        var cross = Path()
        cross.move(to: CGPoint(x: point.x - radius - 4, y: point.y))
        cross.addLine(to: CGPoint(x: point.x + radius + 4, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - radius - 4))
        cross.addLine(to: CGPoint(x: point.x, y: point.y + radius + 4))
        context.stroke(cross, with: .color(.white), style: StrokeStyle(lineWidth: 2))
    }

    /// Runs the clone and writes back to the shared result — which will
    /// itself bump `imageVersion` and trigger `refreshFromCurrentImage()`,
    /// clearing the strokes and source point on its own.
    private func apply() {
        guard let baseImage, containerSize.width > 0, containerSize.height > 0,
              let offset, !strokes.isEmpty else { return }
        isProcessing = true
        errorMessage = nil
        let mask = BrushMask.rasterize(strokes, canvasSize: containerSize, pixelSize: baseImage.size)
        let scale = baseImage.size.width / containerSize.width
        let pixelOffset = CGPoint(x: offset.x * scale, y: offset.y * scale)

        Task {
            do {
                let result = try await CloneStampService.apply(baseImage, maskImage: mask, offset: pixelOffset)
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
        PBEmptyState(icon: "stamp", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    CloneStampView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
