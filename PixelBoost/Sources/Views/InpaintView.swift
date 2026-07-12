import SwiftUI

/// One finger-painted stroke marking part of the photo to erase.
private struct EraseStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var brushSize: CGFloat
}

/// "Object Removal" — paint over something to erase it; the marked area
/// gets filled in via `InpaintingService`'s diffusion fill (see that
/// file's doc comment for why it's not a generative model). Works best on
/// small objects/blemishes over fairly uniform backgrounds.
struct InpaintView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [EraseStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var brushSize: CGFloat = 36
    @State private var containerSize: CGSize = .zero
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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
                                    strokes.append(EraseStroke(points: currentPoints, brushSize: brushSize))
                                }
                                currentPoints = []
                            }
                    )
                    .onAppear { containerSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in containerSize = newSize }
                }
                .aspectRatio(image.size, contentMode: .fit)
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

                if isProcessing {
                    HStack(spacing: 8) {
                        ProgressView().tint(PBColor.accent)
                        Text("Filling in the marked area…")
                            .font(.system(size: 13))
                            .foregroundStyle(PBColor.inkDim)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PBColor.bad)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Object Removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erase") { erase() }
                        .disabled(strokes.isEmpty || isProcessing)
                        .fontWeight(.bold)
                }
            }
        }
        .preferredColorScheme(.dark)
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

    private func erase() {
        guard containerSize.width > 0, containerSize.height > 0, !strokes.isEmpty else { return }
        isProcessing = true
        errorMessage = nil
        let mask = maskImage(canvasSize: containerSize)

        Task {
            do {
                let result = try await InpaintingService.fill(image, maskImage: mask)
                Haptics.success()
                onDone(result)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
            isProcessing = false
        }
    }

    /// Rasterizes `strokes` (in canvas-space points) into a black/white
    /// mask at the source image's own pixel size, using the same single-
    /// uniform-scale-factor conversion `CropRotateView.finalImage()` and
    /// `OverlayCompositor` both use — safe because the canvas is always
    /// sized to exactly the image's aspect ratio.
    private func maskImage(canvasSize: CGSize) -> UIImage {
        let scale = image.size.width / canvasSize.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { rendererContext in
            UIColor.black.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: image.size))

            let cgContext = rendererContext.cgContext
            cgContext.setStrokeColor(UIColor.white.cgColor)
            cgContext.setLineCap(.round)
            cgContext.setLineJoin(.round)
            for stroke in strokes {
                guard let first = stroke.points.first else { continue }
                cgContext.setLineWidth(stroke.brushSize * scale)
                cgContext.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
                for point in stroke.points.dropFirst() {
                    cgContext.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
                }
                cgContext.strokePath()
            }
        }
    }
}

#Preview {
    InpaintView(image: UIImage(systemName: "photo")!) { _ in }
}
