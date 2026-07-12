import SwiftUI

/// One-tap filter picker — a horizontal strip of thumbnails, each showing
/// the *actual* filter rendered against this photo (not a generic swatch),
/// tap one to preview it large above. Thumbnails are rendered once up
/// front against a small preview copy — running every filter against the
/// full-resolution photo just to build a picker strip would be wasteful.
struct FiltersView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: PhotoFilter = .none
    @State private var previewImage: UIImage
    @State private var thumbnails: [PhotoFilter: UIImage] = [:]
    private let previewSource: UIImage
    private let thumbnailSource: UIImage

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        self.image = image
        self.onDone = onDone
        let preview = Self.downscaled(image, maxDimension: 800)
        previewSource = preview
        _previewImage = State(initialValue: preview)
        thumbnailSource = Self.downscaled(image, maxDimension: 160)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(PhotoFilter.allCases) { filter in
                            filterThumbnail(filter)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Spacer()
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(selectedFilter.apply(to: image))
                        dismiss()
                    }
                    .disabled(selectedFilter == .none)
                    .fontWeight(.bold)
                }
            }
            .task {
                await buildThumbnails()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func filterThumbnail(_ filter: PhotoFilter) -> some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail = thumbnails[filter] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black.opacity(0.2)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selectedFilter == filter ? PBColor.accent : PBColor.line,
                        lineWidth: selectedFilter == filter ? 2 : 1
                    )
            )

            Text(filter.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selectedFilter == filter ? PBColor.ink : PBColor.inkDim)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.lightImpact()
            selectedFilter = filter
            previewImage = filter.apply(to: previewSource)
        }
    }

    private func buildThumbnails() async {
        // Off the main actor — ten CIContext renders in a row is cheap at
        // this thumbnail size but still worth keeping off the UI thread.
        let source = thumbnailSource
        let rendered = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: PhotoFilter.allCases.map { ($0, $0.apply(to: source)) })
        }.value
        thumbnails = rendered
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
    FiltersView(image: UIImage(systemName: "photo")!) { _ in }
}
