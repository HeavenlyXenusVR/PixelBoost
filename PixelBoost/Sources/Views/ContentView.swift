import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Upscale screen, top to bottom: the photo (or the live upscale, or
/// the before/after comparison), the run setup right where you use it
/// (model, scale, quality, power — no trip to Settings), an exact plan of
/// what the run will produce, then the result's actions.
struct ContentView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @EnvironmentObject private var provider: UpscalerProvider
    @StateObject private var cloudBackupStatus = CloudBackupStatus.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var zoomedImage: UIImage?
    @State private var isInspecting = false
    @State private var isPreviewingPatch = false
    @State private var isBackingUp = false
    @State private var backupAlertMessage: String?
    @State private var isPresentingEXRImporter = false
    @State private var isPresentingModelPicker = false
    @State private var exrImportErrorMessage: String?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    banners
                    hero
                    if isRunning {
                        runPanel
                    } else if viewModel.sourceImage != nil {
                        if viewModel.resultImage != nil {
                            resultPanel
                        }
                        setupPanel
                        planPanel
                        primaryAction
                    } else {
                        importPanel
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.octagon")
                            .pbFont(.caption)
                            .foregroundStyle(PBColor.bad)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(PBColor.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if viewModel.sourceImage != nil, !isRunning {
                        compactImportRow
                    }
                }
                .padding(PBLayout.gutter)
            }
            .scrollDismissesKeyboard(.immediately)
            .pbScreen("PixelBoost", tool: false)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PBUndoRedoButtons()
                }
            }
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                await viewModel.load(from: pickerItem)
            }
            .fileImporter(
                isPresented: $isPresentingEXRImporter,
                allowedContentTypes: [UTType(filenameExtension: "exr") ?? .data]
            ) { result in
                switch result {
                case .success(let url): loadEXR(from: url)
                case .failure(let error): exrImportErrorMessage = error.localizedDescription
                }
            }
            .alert("Import EXR", isPresented: Binding(
                get: { exrImportErrorMessage != nil },
                set: { if !$0 { exrImportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exrImportErrorMessage ?? "")
            }
            .alert("Saved", isPresented: $viewModel.savedConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveConfirmationMessage)
            }
            .alert("Cloud Backup", isPresented: Binding(
                get: { backupAlertMessage != nil },
                set: { if !$0 { backupAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backupAlertMessage ?? "")
            }
            .sheet(isPresented: $isPresentingModelPicker) {
                ModelPickerView(provider: provider)
                    .preferredColorScheme(.dark)
            }
            .fullScreenCover(isPresented: Binding(
                get: { zoomedImage != nil },
                set: { if !$0 { zoomedImage = nil } }
            )) {
                if let zoomedImage { ZoomableImageView(image: zoomedImage) }
            }
            .fullScreenCover(isPresented: $isInspecting) {
                if let result = viewModel.resultImage {
                    PixelInspectorView(
                        before: viewModel.sourceImage,
                        after: result,
                        display: viewModel.displayResult ?? result.downsampledForDisplay(maxDimension: 2048)
                    )
                }
            }
            .fullScreenCover(isPresented: $isPreviewingPatch) {
                if let display = viewModel.displayResult ?? viewModel.displaySource {
                    PatchPreviewView(display: display)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasSeenOnboarding },
                set: { if !$0 { hasSeenOnboarding = true } }
            )) {
                OnboardingView { hasSeenOnboarding = true }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !viewModel.comparisonResults.isEmpty },
                set: { if !$0 { viewModel.dismissComparison() } }
            )) {
                ModelComparisonView(
                    results: viewModel.comparisonResults,
                    onPick: { viewModel.pickComparisonResult($0) },
                    onSaveAll: { viewModel.saveAllComparisonResultsToPhotos() }
                )
            }
        }
    }

    private var isRunning: Bool { viewModel.isUpscaling || viewModel.isComparing }

    /// Auto + a model-capable quality preset means Compare Models; Fast is
    /// plain resampling, so there's only ever one possible result.
    private var isCompareMode: Bool {
        provider.modelChoice == .auto && provider.quality != .fast
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if isRunning, let source = viewModel.displayResult ?? viewModel.displaySource {
            PBImageFrame {
                LiveUpscaleCanvas(source: source, frame: viewModel.liveFrame, isPaused: viewModel.isPaused)
            }
            .frame(maxHeight: 420)
        } else if let before = viewModel.displaySource, let after = viewModel.displayResult {
            VStack(spacing: 8) {
                PBImageFrame {
                    ZStack(alignment: .top) {
                        CompareSliderView(before: before, after: after)
                            .aspectRatio(after.size.width / max(1, after.size.height), contentMode: .fit)
                        HStack {
                            PBTag(text: "BEFORE")
                            Spacer()
                            if let cg = viewModel.resultImage?.cgImage {
                                PBTag(text: "\(cg.width)×\(cg.height)")
                            }
                        }
                        .padding(10)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: 420)
                Text("Drag to compare · Inspect for pixel-level detail")
                    .pbFont(.caption)
                    .foregroundStyle(PBColor.inkFaint)
            }
        } else if let image = viewModel.displayResult ?? viewModel.displaySource {
            PBImageFrame {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    if let cg = (viewModel.resultImage ?? viewModel.sourceImage)?.cgImage {
                        PBTag(text: "\(cg.width)×\(cg.height)")
                            .padding(10)
                    }
                }
            }
            .frame(maxHeight: 420)
            .onTapGesture { zoomedImage = viewModel.resultImage ?? viewModel.sourceImage }
        } else if viewModel.sourceImage != nil {
            // Display copy still being prepared.
            PBImageFrame {
                ProgressView().tint(PBColor.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
            }
        } else {
            emptyHero
        }
    }

    private var emptyHero: some View {
        VStack(spacing: 14) {
            PixelMark()
                .frame(width: 64, height: 64)
            Text("Upscale every pixel")
                .pbFont(.display)
                .foregroundStyle(PBColor.ink)
            Text("On-device AI that runs your whole photo through the model at full resolution — no shortcuts, no uploads.")
                .pbFont(.body)
                .foregroundStyle(PBColor.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .pbGlassSurface(cornerRadius: 24)
    }

    // MARK: - Import

    private var importPanel: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose Photo", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.pbGradient)
            .simultaneousGesture(TapGesture().onEnded { Haptics.lightImpact() })
            HStack(spacing: 10) {
                Button {
                    viewModel.loadFromPasteboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.pbIcon)
                Button {
                    Haptics.lightImpact()
                    isPresentingEXRImporter = true
                } label: {
                    Label("EXR Render", systemImage: "cube")
                }
                .buttonStyle(.pbIcon)
            }
        }
    }

    private var compactImportRow: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("New Photo", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.pbIcon)
            Button { viewModel.loadFromPasteboard() } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.pbIcon)
            Button {
                Haptics.lightImpact()
                isPresentingEXRImporter = true
            } label: {
                Label("EXR", systemImage: "cube")
            }
            .buttonStyle(.pbIcon)
        }
    }

    // MARK: - Setup

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Haptics.lightImpact()
                isPresentingModelPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: provider.modelChoice.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PBColor.accent)
                        .frame(width: 36, height: 36)
                        .background(PBColor.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MODEL").pbFont(.eyebrow).foregroundStyle(PBColor.inkFaint)
                        Text(provider.quality == .fast ? "Lanczos (Fast quality)" : provider.modelChoice.displayName)
                            .pbFont(.headline)
                            .foregroundStyle(PBColor.ink)
                    }
                    Spacer()
                    if provider.isLoadingModel || provider.isTestingModels {
                        ProgressView().tint(PBColor.accent)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PBColor.inkFaint)
                }
            }
            .buttonStyle(.plain)

            setupRow("Scale") {
                PBSegmented(options: UpscaleFactor.allCases, selection: $provider.scaleFactor, label: { $0.displayName })
            }
            setupRow("Quality") {
                PBSegmented(options: [UpscaleQuality.fast, .standard, .best], selection: qualityBinding, label: { $0.displayName })
            }
            if provider.quality != .fast {
                setupRow("Fidelity") {
                    PBSegmented(options: UpscaleFidelity.allCases, selection: $provider.fidelity, label: { $0.displayName })
                }
                Text(provider.fidelity.footnote)
                    .pbFont(.caption)
                    .foregroundStyle(PBColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                setupRow("Power") {
                    PBSegmented(options: UpscalePower.allCases, selection: $provider.power, label: { $0.displayName }, icon: { $0.systemImage })
                }
                Text(powerFootnote)
                    .pbFont(.caption)
                    .foregroundStyle(PBColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .pbGlassSurface(cornerRadius: 20)
    }

    /// Custom overlap still lives in Settings; shown here as Best's slot
    /// selected so the control never looks empty.
    private var qualityBinding: Binding<UpscaleQuality> {
        Binding(
            get: { provider.quality == .custom ? .best : provider.quality },
            set: { provider.quality = $0 }
        )
    }

    private var powerFootnote: String {
        var text = provider.power.footnote
        if ProcessInfo.processInfo.isLowPowerModeEnabled, provider.power != .efficiency {
            text += " Low Power Mode is on, so Efficiency is used."
        }
        return text
    }

    private func setupRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).pbFont(.eyebrow).foregroundStyle(PBColor.inkFaint)
            control()
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private var planPanel: some View {
        if let plan = viewModel.plan(), let cg = (viewModel.resultImage ?? viewModel.sourceImage)?.cgImage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.square")
                        .foregroundStyle(PBColor.good)
                    Text(provider.quality == .fast ? "Resampled — no model" : "Every pixel through the model")
                        .pbFont(.headline)
                        .foregroundStyle(PBColor.ink)
                    Spacer()
                }
                HStack(spacing: 12) {
                    PBMetric(label: "Input", value: "\(cg.width)×\(cg.height)")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PBColor.inkFaint)
                    PBMetric(label: "Output", value: "\(plan.outputWidth)×\(plan.outputHeight)", tint: PBColor.accent)
                }
                HStack(spacing: 12) {
                    PBMetric(label: "Megapixels", value: String(format: "%.1f", plan.outputMegapixels))
                    PBMetric(label: "Tiles", value: plan.tiles > 0 ? "\(plan.tiles)" : "—")
                    PBMetric(label: "Estimate", value: estimateText(plan))
                }
                if plan.outputWasCapped {
                    Label("That size won't fit in this phone's memory, so the output is \(plan.outputWidth)×\(plan.outputHeight). The model still processes every one of the \(cg.width * cg.height / 1_000_000) MP in your photo.", systemImage: "memorychip")
                        .pbFont(.caption)
                        .foregroundStyle(PBColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isCompareMode {
                    Text("Auto runs every bundled model so you can pick by eye — the estimate is per model.")
                        .pbFont(.caption)
                        .foregroundStyle(PBColor.inkFaint)
                }
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                   provider.power.effective != .efficiency {
                    HStack(spacing: 10) {
                        Label("The phone is already hot — it'll throttle and drain faster.", systemImage: "thermometer.high")
                            .pbFont(.caption)
                            .foregroundStyle(PBColor.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Use Efficiency") { provider.power = .efficiency }
                            .font(.system(size: 12.5, weight: .semibold))
                            .tint(PBColor.accent)
                    }
                }
                if provider.quality != .fast {
                    Button {
                        Haptics.lightImpact()
                        isPreviewingPatch = true
                    } label: {
                        Label(isCompareMode ? "Preview every model on a patch" : "Preview on a patch first", systemImage: "square.dashed.inset.filled")
                    }
                    .buttonStyle(.pbGhost)
                }
            }
            .padding(14)
            .pbGlassSurface(cornerRadius: 20)
        }
    }

    private func estimateText(_ plan: UpscalePlan) -> String {
        if provider.quality == .fast { return "<1s" }
        guard let seconds = plan.estimatedSeconds else { return "learning" }
        return "~" + UpscaleEstimator.format(seconds: seconds)
    }

    private var primaryAction: some View {
        Button {
            Haptics.lightImpact()
            if isCompareMode { viewModel.compareModels() } else { viewModel.upscale() }
        } label: {
            Label(
                isCompareMode ? "Compare Models" : (viewModel.resultImage == nil ? "Upscale" : "Upscale Current Edit"),
                systemImage: isCompareMode ? "square.grid.2x2" : "wand.and.stars"
            )
        }
        .buttonStyle(.pbGradient)
        .disabled(viewModel.isBusy)
    }

    // MARK: - Running

    private var runPanel: some View {
        let fraction = viewModel.isComparing ? viewModel.comparisonProgress : viewModel.progress
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(PBColor.ink)
                Text(viewModel.isPaused ? "paused" : (viewModel.isComparing ? "comparing models" : "upscaling"))
                    .pbFont(.body)
                    .foregroundStyle(PBColor.inkDim)
                Spacer()
                if viewModel.liveFrame?.isThermalPaced == true {
                    Label("Cooling", systemImage: "thermometer.medium")
                        .pbFont(.caption)
                        .foregroundStyle(PBColor.warn)
                }
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(PBColor.accent)
            HStack(spacing: 12) {
                if let frame = viewModel.liveFrame {
                    PBMetric(label: frame.tilesReused > 0 ? "Tiles (\(frame.tilesReused) reused)" : "Tiles", value: "\(frame.tilesDone)/\(frame.tilesTotal)")
                    PBMetric(label: "Pixels", value: String(format: "%.1f/%.1f MP", Double(frame.pixelsDone) / 1_000_000, Double(frame.pixelsTotal) / 1_000_000))
                } else {
                    PBMetric(label: "Tiles", value: "—")
                    PBMetric(label: "Pixels", value: "preparing")
                }
                if let started = viewModel.runStartedAt {
                    // Once a second is plenty for a clock and costs nothing.
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(started)
                        PBMetric(label: fraction > 0.03 && !viewModel.isPaused ? "Remaining" : "Elapsed",
                                 value: fraction > 0.03 && !viewModel.isPaused
                                    ? UpscaleEstimator.format(seconds: elapsed / fraction * (1 - fraction))
                                    : UpscaleEstimator.format(seconds: elapsed))
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    viewModel.togglePause()
                } label: {
                    Label(viewModel.isPaused ? "Resume" : "Pause", systemImage: viewModel.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.pbGhost)
                Button(role: .destructive) {
                    viewModel.cancelRun()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.pbGhost)
            }
            Text("Running on \(provider.power.effective.displayName). You can switch tabs or pause to let the phone cool — nothing processed so far is lost.")
                .pbFont(.caption)
                .foregroundStyle(PBColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .pbGlassSurface(cornerRadius: 20)
    }

    // MARK: - Result

    @ViewBuilder
    private var resultPanel: some View {
        if let resultImage = viewModel.resultImage {
            VStack(spacing: 12) {
                if let summary = viewModel.lastRunSummary {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            PBMetric(label: "Model", value: summary.modelName)
                            PBMetric(label: "Time", value: UpscaleEstimator.format(seconds: summary.seconds))
                        }
                        HStack(spacing: 12) {
                            PBMetric(label: "Fidelity", value: summary.fidelityPSNR.map { String(format: "%.1f dB", $0) } ?? "—",
                                     tint: (summary.fidelityPSNR ?? 0) >= 40 ? PBColor.good : PBColor.ink)
                            PBMetric(label: "Tiles", value: summary.tiles.map { tiles in
                                summary.tilesReused > 0 ? "\(tiles) (\(summary.tilesReused) reused)" : "\(tiles)"
                            } ?? "—")
                        }
                    }
                    .padding(14)
                    .pbGlassSurface(cornerRadius: 18)
                }

                Button {
                    viewModel.saveResultToPhotos()
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.pbGradient)

                HStack(spacing: 10) {
                    ShareLink(
                        item: Image(uiImage: resultImage),
                        preview: SharePreview("PixelBoost", image: Image(uiImage: viewModel.displayResult ?? resultImage))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.pbIcon)

                    Button {
                        UIPasteboard.general.image = resultImage
                        Haptics.lightImpact()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.pbIcon)

                    Button {
                        Haptics.lightImpact()
                        isInspecting = true
                    } label: {
                        Label("Inspect", systemImage: "square.grid.3x3.middle.filled")
                    }
                    .buttonStyle(.pbIcon)

                    Button {
                        viewModel.revertToOriginal()
                    } label: {
                        Label("Original", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.pbIcon)

                    if ServerConfig.baseURL != nil {
                        Button {
                            Task { await backupResultToCloud(resultImage) }
                        } label: {
                            Label(isBackingUp ? "Sending" : "Cloud", systemImage: "icloud.and.arrow.up")
                        }
                        .buttonStyle(.pbIcon)
                        .disabled(isBackingUp)
                    }
                }
            }
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if !provider.modelChoice.isBundled {
            banner("No Core ML model bundled — using basic resampling. See Models/README.md.", icon: "exclamationmark.triangle")
        }
        if provider.autoCloudBackupEnabled, let message = cloudBackupStatus.lastFailureMessage {
            Button {
                cloudBackupStatus.dismiss()
            } label: {
                banner("Auto Cloud Backup failed: \(message)", icon: "icloud.slash")
            }
            .buttonStyle(.plain)
        }
    }

    private func banner(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .pbFont(.caption)
            .foregroundStyle(PBColor.warn)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PBColor.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

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

    /// Security-scoped URL from `.fileImporter`; decode + tonemap off the
    /// main thread.
    private func loadEXR(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            exrImportErrorMessage = "Couldn't access that file."
            return
        }
        Task {
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try EXRImportService.loadImage(from: url)
                }.value
                viewModel.loadSharedImage(image)
                Haptics.success()
                ActionLoggingService.log("exr_import", detail: ["outcome": "success"])
            } catch {
                exrImportErrorMessage = error.localizedDescription
                Haptics.error()
                ActionLoggingService.log("exr_import", detail: ["outcome": "failed", "error": error.localizedDescription])
            }
        }
    }

    private func backupResultToCloud(_ image: UIImage) async {
        isBackingUp = true
        do {
            _ = try await ImportExportService.upload(image, kind: .exports)
            backupAlertMessage = "Backed up to cloud — it'll stay available for 24 hours (see it under Tools › Cloud)."
            Haptics.success()
        } catch {
            backupAlertMessage = error.localizedDescription
            Haptics.error()
        }
        isBackingUp = false
    }
}

/// The app's mark: a 4×4 pixel grid resolving from coarse to fine —
/// drawn, not an asset.
struct PixelMark: View {
    var body: some View {
        Canvas { context, size in
            let n = 4
            let cell = size.width / CGFloat(n)
            for row in 0..<n {
                for column in 0..<n {
                    let t = Double(row + column) / Double(2 * (n - 1))
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        .insetBy(dx: cell * 0.08, dy: cell * 0.08)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: cell * 0.22),
                        with: .color(PBColor.accent.opacity(0.25 + 0.75 * t))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    let provider = UpscalerProvider()
    ContentView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
