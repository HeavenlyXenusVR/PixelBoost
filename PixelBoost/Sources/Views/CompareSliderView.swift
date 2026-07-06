import SwiftUI

/// Interactive draggable-divider "reveal" comparator: before on the left of
/// the divider, after on the right, drag anywhere to move it.
///
/// Safe regarding before/after having different pixel dimensions —
/// `ImageTiler.outputSize` is always exactly `imageWidth*scaleFactor x
/// imageHeight*scaleFactor`, so both images share the same aspect ratio and
/// `.aspectRatio(.fit)` inside the same fixed frame lands them in the
/// identical on-screen rect with no extra alignment math needed.
struct CompareSliderView: View {
    let before: UIImage
    let after: UIImage

    @State private var dividerFraction: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let dividerX = width * dividerFraction

            ZStack(alignment: .leading) {
                Image(uiImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)

                Image(uiImage: before)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .frame(width: dividerX, alignment: .leading)
                    .clipped()

                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .shadow(radius: 2)
                    .offset(x: dividerX - 1)

                Circle()
                    .fill(.white)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                    )
                    .shadow(radius: 2)
                    .offset(x: dividerX - 16, y: height / 2 - 16)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // The whole area is draggable, not just the handle — a thin
            // divider line is a poor drag target on a phone.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dividerFraction = max(0, min(1, value.location.x / width))
                    }
            )
        }
    }
}
