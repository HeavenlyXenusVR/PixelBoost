import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @EnvironmentObject private var provider: UpscalerProvider
    @State private var pickerItem: PhotosPickerItem?
    @State private var zoomedImage: UIImage?
    @State private var isBackingUp = false
    @State private var backupAlertMessage: String?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !provider.modelChoice.isBundled {
                        modelMissingBanner
                    }

                    imagePreview

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .simultaneousGesture(TapGesture().onEnded { Haptics.lightImpact() })

                    if viewModel.sourceImage != nil {
                        Button {
                            Haptics.lightImpact()
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

                    if let resultImage = viewModel.resultImage {
                        Button {
                            viewModel.saveResultToPhotos()
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        HStack(spacing: 12) {
                            ShareLink(
                                item: Image(uiImage: resultImage),
                                preview: SharePreview("Upscaled Photo", image: Image(uiImage: resultImage))
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                UIPasteboard.general.image = resultImage
                                Haptics.lightImpact()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        if ServerConfig.baseURL != nil {
                            Button {
                                Task { await backupResultToCloud(resultImage) }
                            } label: {
                                Label(
                                    isBackingUp ? "Backing Up…" : "Backup to Cloud",
                                    systemImage: "icloud.and.arrow.up"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isBackingUp)
                        }
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
            .navigationTitle("PixelBoost")
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                await viewModel.load(from: pickerItem)
            }
            .alert("Saved", isPresented: $viewModel.savedConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The upscaled image was added to your Photos library.")
            }
            .alert("Cloud Backup", isPresented: Binding(
                get: { backupAlertMessage != nil },
                set: { isPresented in if !isPresented { backupAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backupAlertMessage ?? "")
            }
            .fullScreenCover(isPresented: Binding(
                get: { zoomedImage != nil },
                set: { isPresented in if !isPresented { zoomedImage = nil } }
            )) {
                if let zoomedImage {
                    ZoomableImageView(image: zoomedImage)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasSeenOnboarding },
                set: { isPresented in if !isPresented { hasSeenOnboarding = true } }
            )) {
                OnboardingView { hasSeenOnboarding = true }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        BatchUpscaleView(provider: provider)
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    NavigationLink {
                        CloudView()
                    } label: {
                        Image(systemName: "icloud")
                    }
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    private func backupResultToCloud(_ image: UIImage) async {
        isBackingUp = true
        do {
            _ = try await ImportExportService.upload(image, kind: .exports)
            backupAlertMessage = "Backed up to cloud — it'll stay available for 24 hours (see it under the cloud icon)."
            Haptics.success()
        } catch {
            backupAlertMessage = error.localizedDescription
            Haptics.error()
        }
        isBackingUp = false
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let sourceImage = viewModel.sourceImage, let resultImage = viewModel.resultImage {
            VStack(spacing: 6) {
                CompareSliderView(before: sourceImage, after: resultImage)
                    .frame(height: 320)
                Text("Before/After · drag to compare · \(Int(resultImage.size.width))×\(Int(resultImage.size.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let resultImage = viewModel.resultImage {
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
                .onTapGesture { zoomedImage = image }
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
    let provider = UpscalerProvider()
    ContentView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
