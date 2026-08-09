import SwiftUI

/// Full-screen pinch-to-zoom + pan + double-tap-to-zoom image viewer.
struct ZoomableImageView: View {
    /// Downsampled for display — see
    /// `UIImage.downsampledForDisplay(maxDimension:)`'s doc comment; a
    /// tens-of-megapixel upscale result handed straight to a live,
    /// gesture-driven SwiftUI `Image` renders as torn/sliced bands on real
    /// hardware. 4096 (not this view's own smaller `CompareSliderView`
    /// cap) — up to 5x pinch zoom on top of "fit" means this view needs
    /// real detail in reserve, not just enough to fill the screen once.
    private let image: UIImage
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    init(image: UIImage) {
        self.image = image.downsampledForDisplay(maxDimension: 4096)
    }

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(magnifyGesture)
                .simultaneousGesture(dragGesture)
                .onTapGesture(count: 2, perform: toggleZoom)
                .background(Color.black.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(.white)
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                scale = 2.5
            }
            lastScale = scale
            lastOffset = offset
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, min(lastScale * value, 5))
            }
            .onEnded { _ in
                lastScale = scale
                if scale == 1 { offset = .zero; lastOffset = .zero }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}
