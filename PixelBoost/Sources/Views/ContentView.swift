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
    @State private var isPresentingAdjustments = false
    @State private var isPresentingCropRotate = false
    @State private var isPresentingFilters = false
    @State private var isPresentingOverlays = false
    @State private var isPresentingInpaint = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if !provider.modelChoice.isBundled {
                        modelMissingBanner
                    }

                    imagePreview

                    PhotosPicker(selection: $pickerItem, matching: .images) {
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

                        toolStrip
                    }

                    if viewModel.isComparing {
                        VStack(spacing: 6) {
                            ProgressView(value: viewModel.comparisonProgress)
                                .progressViewStyle(.linear)
                                .tint(PBColor.accent)
                            Text("Running every model on your photo… \(Int(viewModel.comparisonProgress * 100))%")
                                .font(.system(size: 13))
                                .foregroundStyle(PBColor.inkDim)
                        }
                    } else if viewModel.isUpscaling {
                        VStack(spacing: 6) {
                            ProgressView(value: viewModel.progress)
                                .progressViewStyle(.linear)
                                .tint(PBColor.accent)
                            Text("Upscaling… \(Int(viewModel.progress * 100))%")
                                .font(.system(size: 13))
                                .foregroundStyle(PBColor.inkDim)
                        }
                    } else if viewModel.isRemovingBackground {
                        HStack(spacing: 8) {
                            ProgressView().tint(PBColor.accent)
                            Text("Finding the subject to cut out…")
                                .font(.system(size: 13))
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
            .fullScreenCover(isPresented: $isPresentingAdjustments) {
                if let currentImage {
                    AdjustmentsView(image: currentImage) { viewModel.resultImage = $0 }
                }
            }
            .fullScreenCover(isPresented: $isPresentingCropRotate) {
                if let currentImage {
                    CropRotateView(image: currentImage) { viewModel.resultImage = $0 }
                }
            }
            .fullScreenCover(isPresented: $isPresentingFilters) {
                if let currentImage {
                    FiltersView(image: currentImage) { viewModel.resultImage = $0 }
                }
            }
            .fullScreenCover(isPresented: $isPresentingOverlays) {
                if let currentImage {
                    OverlaysView(image: currentImage) { viewModel.resultImage = $0 }
                }
            }
            .fullScreenCover(isPresented: $isPresentingInpaint) {
                if let currentImage {
                    InpaintView(image: currentImage) { viewModel.resultImage = $0 }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 2) {
                        NavigationLink { BatchUpscaleView(provider: provider) } label: {
                            toolbarIcon("square.stack")
                        }
                        NavigationLink { CloudView() } label: {
                            toolbarIcon("icloud")
                        }
                        NavigationLink { HistoryView() } label: {
                            toolbarIcon("clock.arrow.circlepath")
                        }
                        NavigationLink { SettingsView() } label: {
                            toolbarIcon("gearshape")
                        }
                    }
                    .padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(PBColor.line, lineWidth: 1))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Auto + a model-capable quality preset means there's something to
    /// compare; Fast skips models entirely (plain Lanczos resampling), so
    /// there's only ever one possible result and a normal single upscale
    /// is what actually happens either way.
    private var isCompareMode: Bool {
        provider.modelChoice == .auto && provider.quality != .fast
    }

    /// Only one tool at a time — Upscale/Compare Models and Cutout both
    /// write to `resultImage` and share the same source photo, so running
    /// two at once would just race each other.
    private var isAnyToolRunning: Bool {
        viewModel.isUpscaling || viewModel.isComparing || viewModel.isRemovingBackground
    }

    /// What Cutout/Adjust/Crop all operate on — the most-recent result if
    /// there is one, so these tools chain onto each other (crop the
    /// upscaled photo, adjust the cutout, etc.) instead of always
    /// reaching back to the original.
    private var currentImage: UIImage? {
        viewModel.resultImage ?? viewModel.sourceImage
    }

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                toolChip("Cutout", systemImage: "scissors") {
                    viewModel.removeBackground()
                }
                toolChip("Adjust", systemImage: "slider.horizontal.3") {
                    isPresentingAdjustments = true
                }
                toolChip("Crop", systemImage: "crop") {
                    isPresentingCropRotate = true
                }
                toolChip("Filters", systemImage: "camera.filters") {
                    isPresentingFilters = true
                }
                toolChip("Overlays", systemImage: "textformat") {
                    isPresentingOverlays = true
                }
                toolChip("Erase", systemImage: "eraser") {
                    isPresentingInpaint = true
                }
            }
        }
    }

    private func toolChip(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.lightImpact()
            action()
        } label: {
            Label(label, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PBColor.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(PBColor.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(PBColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isAnyToolRunning)
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PBColor.ink)
            .frame(width: 30, height: 30)
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
                Text("Drag to compare")
                    .font(.system(size: 12))
                    .foregroundStyle(PBColor.inkFaint)
            }
        } else if let resultImage = viewModel.resultImage {
            labeledImage("After", image: resultImage)
        } else if let sourceImage = viewModel.sourceImage {
            labeledImage("Before", image: sourceImage)
        } else {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PBColor.accentGradient)
                        .frame(width: 52, height: 52)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("No Photo Yet")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(PBColor.ink)
                Text("Choose a photo — Auto runs every model so you can compare and pick.")
                    .font(.system(size: 13))
                    .foregroundStyle(PBColor.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(
                LinearGradient(colors: [PBColor.accent.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(PBColor.line)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { zoomedImage = image }
            Text("\(label) · \(Int(image.size.width))×\(Int(image.size.height))")
                .font(.system(size: 12))
                .foregroundStyle(PBColor.inkFaint)
        }
    }

    private var modelMissingBanner: some View {
        Label("No Core ML model bundled — using basic resampling. See Models/README.md.", systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
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
