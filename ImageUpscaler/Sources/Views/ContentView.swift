import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = UpscalerViewModel()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !viewModel.isUsingMLModel {
                        modelMissingBanner
                    }

                    imagePreview

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if viewModel.sourceImage != nil {
                        Button {
                            viewModel.upscale()
                        } label: {
                            Label("Upscale", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isUpscaling)
                    }

                    if viewModel.isUpscaling {
                        ProgressView(value: viewModel.progress)
                            .progressViewStyle(.linear)
                        Text("Upscaling… \(Int(viewModel.progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.resultImage != nil {
                        Button {
                            viewModel.saveResultToPhotos()
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Upscaler")
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                await viewModel.load(from: pickerItem)
            }
            .alert("Saved", isPresented: $viewModel.savedConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The upscaled image was added to your Photos library.")
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let resultImage = viewModel.resultImage {
            labeledImage("After", image: resultImage)
        } else if let sourceImage = viewModel.sourceImage {
            labeledImage("Before", image: sourceImage)
        } else {
            // Not using ContentUnavailableView — it needs iOS 17, and this
            // app targets 16.
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No Photo Selected")
                    .font(.headline)
                Text("Choose a photo to upscale it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
    }

    private func labeledImage(_ label: String, image: UIImage) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("\(label) · \(Int(image.size.width))×\(Int(image.size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelMissingBanner: some View {
        Label("No Core ML model bundled — using basic resampling. See Models/README.md.", systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview {
    ContentView()
}
