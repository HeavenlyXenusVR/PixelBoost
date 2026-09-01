import SwiftUI

/// Mask the photo into a shape — circle, square, and 10 more (see
/// `FrameShape`) — picked from a chip row, previewed live via
/// `.clipShape`. Lives as its own persistent tab (see `RootView`), same
/// "Apply bakes onto the shared result, stay right here" pattern as
/// `CropRotateView` and `OverlaysView`.
struct FramesView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var workingImage: UIImage?
    @State private var lastBase: UIImage?
    @State private var selectedShape: FrameShape = .circle

    var body: some View {
        NavigationStack {
            Group {
                if let workingImage {
                    VStack(spacing: 20) {
                        PBImageFrame {
                            Image(uiImage: workingImage)
                                .resizable()
                                .scaledToFill()
                                .clipShape(FrameShapePath(shape: selectedShape))
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 40)
                        .padding(.top, 8)

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
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        workingImage = current
    }

    private func apply() {
        guard let workingImage else { return }
        viewModel.resultImage = FrameShapeService.apply(selectedShape, to: workingImage)
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
