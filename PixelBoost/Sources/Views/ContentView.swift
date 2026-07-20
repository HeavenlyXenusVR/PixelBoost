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
                VStack(spacing: 18) {
                    if !provider.modelChoice.isBundled {
                        modelMissingBanner
                    }

                    imagePreview

                    // photoLibrary: .shared() is the initializer's documented
                    // default, but omitting it explicitly leaves
                    // PhotosPickerItem.itemIdentifier nil for every pick,
                    // regardless of Photos authorization — a known
                    // SwiftUI/PhotosUI quirk, not the default actually being
                    // applied. Passing it explicitly is required for
                    // PhotoLibrarySaver's overwrite path to ever have an
                    // identifier to work with.
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.pbGhost)
                    .simultaneousGesture(TapGesture().onEnded { Haptics.lightImpact() })

                    if viewModel.sourceImage != nil {
                        Button {
                            Haptics.lightImpact()
                            if isCompareMode {
                                viewModel.compareModels()
                            } else {
                                viewModel.upscale()
                            }
                        } label: {
                            Label(
                                isCompareMode ? "Compare Models" : "Upscale",
                                systemImage: isCompareMode ? "square.grid.2x2" : "wand.and.stars"
                            )
                        }
                        .buttonStyle(.pbGradient)
                        .disabled(isAnyToolRunning)

                        Text("Edit tools — Cutout, Enhance, Adjust, Selective, Crop, Filters, Overlays, Erase, Restore, Clone Stamp — live in the bar below.")
                            .font(.system(size: 12))
                            .foregroundStyle(PBColor.inkFaint)
                            .multilineTextAlignment(.center)
                    }

                    if viewModel.isComparing {
                        VStack(spacing: 6) {
                            ProgressView(value: viewModel.comparisonProgress)
                                .progressViewStyle(.linear)
                                .tint(PBColor.accent)
                            Text("Running every model on your photo… \(Int(viewModel.comparisonProgress * 100))%")
                                .pbFont(.body)
                                .foregroundStyle(PBColor.inkDim)
                        }
                    } else if viewModel.isUpscaling {
                        VStack(spacing: 6) {
                            ProgressView(value: viewModel.progress)
                                .progressViewStyle(.linear)
                                .tint(PBColor.accent)
                            Text("Upscaling… \(Int(viewModel.progress * 100))%")
                                .pbFont(.body)
                                .foregroundStyle(PBColor.inkDim)
                        }
                    } else if viewModel.isRemovingBackground {
                        HStack(spacing: 8) {
                            ProgressView().tint(PBColor.accent)
                            Text("Finding the subject to cut out…")
                                .pbFont(.body)
                                .foregroundStyle(PBColor.inkDim)
                        }
                    }

                    if let resultImage = viewModel.resultImage {
                        Button {
                            viewModel.saveResultToPhotos()
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.pbGradient)

                        HStack(spacing: 10) {
                            ShareLink(
                                item: Image(uiImage: resultImage),
                                preview: SharePreview("Upscaled Photo", image: Image(uiImage: resultImage))
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.pbGhost)

                            Button {
                                UIPasteboard.general.image = resultImage
                                Haptics.lightImpact()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.pbGhost)
                        }

                        if viewModel.sourceImage != nil {
                            Button {
                                viewModel.revertToOriginal()
                            } label: {
                                Label("Revert to Original", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.pbGhost)
                        }

                        if ServerConfig.baseURL != nil {
                            Button {
                                Task { await backupResultToCloud(resultImage) }
                            } label: {
                                Label(
                                    isBackingUp ? "Backing Up…" : "Backup to Cloud",
                                    systemImage: "icloud.and.arrow.up"
                                )
                            }
                            .buttonStyle(.pbGhost)
                            .disabled(isBackingUp)
                        }
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12.5))
                            .foregroundStyle(PBColor.bad)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("PixelBoost")
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                await viewModel.load(from: pickerItem)
            }
            .alert("Saved", isPresented: $viewModel.savedConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveConfirmationMessage)
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
            .fullScreenCover(isPresented: Binding(
                get: { !viewModel.comparisonResults.isEmpty },
                set: { isPresented in if !isPresented { viewModel.comparisonResults = [] } }
            )) {
                ModelComparisonView(
                    results: viewModel.comparisonResults,
                    onPick: { viewModel.pickComparisonResult($0) },
                    onSaveAll: { viewModel.saveAllComparisonResultsToPhotos() }
                )
            }
        }
    }

    /// Auto + a model-capable quality preset means there's something to
    /// compare; Fast skips models entirely (plain Lanczos resampling), so
    /// there's only ever one possible result and a normal single upscale
    /// is what actually happens either way.
    private var isCompareMode: Bool {
        provider.modelChoice == .auto && provider.quality != .fast
    }

    /// Reflects what `saveResultToPhotos()` actually did, not a fixed
    /// string — an overwrite that silently fell back to adding a new asset
    /// (e.g. the original couldn't be fetched) used to say "added" either
    /// way, which made a failed overwrite indistinguishable from a working
    /// one. Always states the specific reason, not just for actual
    /// failures — Preserve Original / no-source-identifier are "expected",
    /// but silently hiding them just relocates the same "why didn't this
    /// overwrite" confusion one level up. See `PhotoLibrarySaver.SaveOutcome`.
    private var saveConfirmationMessage: String {
        switch viewModel.lastSaveOutcome {
        case .overwroteOriginal:
            return "The original photo was replaced with the edited version."
        case .addedNewAsset(let reason):
            let base = "Saved as a new photo in your library (the original was left untouched)."
            guard let reason else { return base }
            return base + " Reason: \(reason.description)."
        case nil:
            return "Saved as a new photo in your library (the original was left untouched)."
        }
    }

    /// Only one tool at a time — Upscale/Compare Models and Cutout both
    /// write to `resultImage` and share the same source photo, so running
    /// two at once would just race each other.
    private var isAnyToolRunning: Bool {
        viewModel.isUpscaling || viewModel.isComparing || viewModel.isRemovingBackground
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
            VStack(spacing: 8) {
                PBImageFrame {
                    ZStack(alignment: .top) {
                        CompareSliderView(before: sourceImage, after: resultImage)
                            .frame(height: 300)
                        HStack {
                            tag("Before")
                            Spacer()
                            tag("\(Int(resultImage.size.width))×\(Int(resultImage.size.height))")
                        }
                        .padding(10)
                    }
                }
                Text("Drag to compare")
                    .pbFont(.caption)
                    .foregroundStyle(PBColor.inkFaint)
            }
        } else if let resultImage = viewModel.resultImage {
            labeledImage("After", image: resultImage)
        } else if let sourceImage = viewModel.sourceImage {
            labeledImage("Before", image: sourceImage)
        } else {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(PBColor.accentGradient)
                        .frame(width: 56, height: 56)
                        .shadow(color: PBColor.accent.opacity(0.45), radius: 14, x: 0, y: 6)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("No Photo Yet")
                    .pbFont(.title)
                    .foregroundStyle(PBColor.ink)
                Text("Choose a photo — Auto runs every model so you can compare and pick.")
                    .pbFont(.body)
                    .foregroundStyle(PBColor.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .pbGlassSurface(cornerRadius: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .foregroundStyle(PBColor.accent.opacity(0.4))
            )
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private func labeledImage(_ label: String, image: UIImage) -> some View {
        VStack(spacing: 6) {
            PBImageFrame {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
            }
            .onTapGesture { zoomedImage = image }
            Text("\(label) · \(Int(image.size.width))×\(Int(image.size.height))")
                .pbFont(.caption)
                .foregroundStyle(PBColor.inkFaint)
        }
    }

    private var modelMissingBanner: some View {
        Label("No Core ML model bundled — using basic resampling. See Models/README.md.", systemImage: "exclamationmark.triangle")
            .pbFont(.caption)
            .foregroundStyle(PBColor.warn)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PBColor.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(PBColor.warn.opacity(0.22), lineWidth: 1)
            )
    }
}

#Preview {
    let provider = UpscalerProvider()
    ContentView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
