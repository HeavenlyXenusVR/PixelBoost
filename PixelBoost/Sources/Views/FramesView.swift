import SwiftUI

/// Mask the photo into a shape — circle, square, and 10 more (see
/// `FrameShape`) — picked from a chip row, previewed live via
/// `.clipShape`. Pinch to zoom and drag to reposition which part of the
/// photo sits inside the shape before applying, same idea as a standard
/// avatar cropper. Lives as its own persistent tab (see `RootView`), same
/// "Apply bakes onto the shared result, stay right here" pattern as
/// `CropRotateView` and `OverlaysView`.
struct FramesView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var workingImage: UIImage?
    @State private var lastBase: UIImage?
    @State private var selectedShape: FrameShape = .circle

    // Pan/zoom state for positioning the photo inside the frame — same
    // "current value" + "value at gesture start" pairing `ZoomableImageView`
    // uses, just clamped here (see `FrameShapeService.clampedPanOffset`) so
    // the shape can never show a gap past the photo's own edge.
    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var stageSize: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                if let workingImage {
                    VStack(spacing: 20) {
                        PBImageFrame {
                            GeometryReader { geo in
                                Image(uiImage: workingImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .scaleEffect(zoomScale)
                                    .offset(panOffset)
                                    .clipShape(FrameShapePath(shape: selectedShape))
                                    .contentShape(Rectangle())
                                    .gesture(dragGesture(stageSize: geo.size.width))
                                    .simultaneousGesture(magnifyGesture(stageSize: geo.size.width))
                                    .onAppear { stageSize = geo.size.width }
                                    .onChange(of: geo.size.width) { _, newWidth in stageSize = newWidth }
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 40)
                        .padding(.top, 8)

                        Text("Pinch to zoom, drag to reposition.")
                            .pbFont(.caption)
                            .foregroundStyle(PBColor.inkFaint)

                        shapeChipsGrid

                        Button {
                            Haptics.lightImpact()
                            apply()
                        } label: {
                            Label("Apply", systemImage: "checkmark")
                        }
                        .buttonStyle(.pbGradient)
                        .padding(.horizontal, 20)

                        Spacer()
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Frames")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            workingImage = nil
            resetTransform()
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        workingImage = current
        resetTransform()
    }

    private func resetTransform() {
        zoomScale = 1
        lastZoomScale = 1
        panOffset = .zero
        lastPanOffset = .zero
    }

    private func dragGesture(stageSize: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let workingImage else { return }
                let candidate = CGSize(
                    width: lastPanOffset.width + value.translation.width,
                    height: lastPanOffset.height + value.translation.height
                )
                panOffset = FrameShapeService.clampedPanOffset(
                    candidate, imageSize: workingImage.size, stageSize: stageSize, zoomScale: zoomScale
                )
            }
            .onEnded { _ in lastPanOffset = panOffset }
    }

    private func magnifyGesture(stageSize: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = max(1, min(lastZoomScale * value, 4))
            }
            .onEnded { _ in
                guard let workingImage else { return }
                lastZoomScale = zoomScale
                panOffset = FrameShapeService.clampedPanOffset(
                    panOffset, imageSize: workingImage.size, stageSize: stageSize, zoomScale: zoomScale
                )
                lastPanOffset = panOffset
            }
    }

    private func apply() {
        guard let workingImage else { return }
        let cropRect = FrameShapeService.cropRect(
            imageSize: workingImage.size, stageSize: stageSize, zoomScale: zoomScale, panOffset: panOffset
        )
        viewModel.resultImage = FrameShapeService.apply(selectedShape, to: workingImage, cropRect: cropRect)
        Haptics.success()
        ActionLoggingService.log("frame_shape_apply", detail: ["shape": selectedShape.rawValue])
    }

    private var shapeChipsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 68), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(FrameShape.allCases) { shape in
                shapeChip(shape)
            }
        }
        .padding(.horizontal, 20)
    }

    private func shapeChip(_ shape: FrameShape) -> some View {
        let isSelected = shape == selectedShape
        return Button {
            Haptics.lightImpact()
            selectedShape = shape
        } label: {
            VStack(spacing: 6) {
                FrameShapePath(shape: shape)
                    .fill(isSelected ? PBColor.accent : PBColor.inkDim)
                    .frame(width: 30, height: 30)
                    .frame(width: 56, height: 56)
                    .pbGlassSurface(cornerRadius: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? PBColor.accent : .clear, lineWidth: 1.5)
                    )
                Text(shape.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PBColor.inkDim)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        PBEmptyState(icon: "square.on.circle", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    FramesView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
