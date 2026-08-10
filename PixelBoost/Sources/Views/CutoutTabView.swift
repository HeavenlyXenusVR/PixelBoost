import SwiftUI

/// Two modes: "Everything" (the original, still-default behavior — a
/// single unattended action cutting out every detected subject at once)
/// and "Tap to Select" (pick one specific subject by tapping it — see
/// `BackgroundRemovalService`'s "Tap to Select" section). Writes straight
/// to `viewModel.resultImage`, same as every other tool.
private enum CutoutMode: String, CaseIterable, Identifiable {
    case auto, tapToSelect
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Everything"
        case .tapToSelect: return "Tap to Select"
        }
    }
}

struct CutoutTabView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var selectedFill: BackgroundFill?
    @State private var fillPreview: UIImage?
    @State private var isProcessingFill = false

    // Tap to Select — see BackgroundRemovalService's "Tap to Select"
    // section. `VNGenerateForegroundInstanceMaskRequest` already segments
    // every distinct subject separately; this mode exposes that instead of
    // always merging every instance the way "Everything" does.
    @State private var mode: CutoutMode = .auto
    @State private var detectionResult: BackgroundRemovalService.InstanceDetectionResult?
    @State private var isDetecting = false
    @State private var selectedInstance: BackgroundRemovalService.DetectedInstance?
    @State private var tapPreview: UIImage?
    @State private var isProcessingTapPreview = false
    @State private var tapErrorMessage: String?

    private var currentImage: UIImage? {
        viewModel.resultImage ?? viewModel.sourceImage
    }

    private var isAnyToolRunning: Bool {
        viewModel.isUpscaling || viewModel.isComparing || viewModel.isRemovingBackground
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let currentImage {
                        Picker("Mode", selection: $mode) {
                            ForEach(CutoutMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: mode) { _, newMode in
                            if newMode == .tapToSelect { startDetection(currentImage) }
                        }

                        if mode == .auto {
                            autoModeContent(currentImage)
                        } else {
                            tapToSelectContent(currentImage)
                        }

                        if currentImage.hasAlphaChannel {
                            backgroundReplaceSection
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(20)
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Cutout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in
                selectedFill = nil
                fillPreview = nil
                detectionResult = nil
                selectedInstance = nil
                tapPreview = nil
                tapErrorMessage = nil
                if mode == .tapToSelect, let currentImage {
                    startDetection(currentImage)
                }
            }
        }
    }

    @ViewBuilder
    private func autoModeContent(_ currentImage: UIImage) -> some View {
        PBImageFrame {
            Image(uiImage: fillPreview ?? currentImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 340)
        }

        Text("Cuts every subject out of your photo with a transparent background, using on-device subject detection — the same technology behind Photos' \"Lift Subject.\"")
            .pbFont(.body)
            .foregroundStyle(PBColor.inkDim)
            .multilineTextAlignment(.center)

        Button {
            Haptics.lightImpact()
            viewModel.removeBackground()
        } label: {
            Label("Remove Background", systemImage: "scissors")
        }
        .buttonStyle(.pbGradient)
        .disabled(isAnyToolRunning)

        if viewModel.isRemovingBackground {
            HStack(spacing: 8) {
                ProgressView().tint(PBColor.accent)
                Text("Finding the subject to cut out…")
                    .pbFont(.body)
                    .foregroundStyle(PBColor.inkDim)
            }
        }

        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .pbFont(.caption)
                .foregroundStyle(PBColor.bad)
                .multilineTextAlignment(.center)
        }
    }

    /// One tap anywhere on the photo picks whichever detected subject
    /// covers that point (see `BackgroundRemovalService`'s "Tap to
    /// Select" section) — for a group photo or a table of objects, where
    /// "Everything" mode would cut out every subject at once instead of
    /// letting you pick just one.
    @ViewBuilder
    private func tapToSelectContent(_ currentImage: UIImage) -> some View {
        PBImageFrame {
            GeometryReader { geo in
                Image(uiImage: tapPreview ?? currentImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        // Plain `.onTapGesture` has no location-providing
                        // overload in SwiftUI — a zero-minimum-distance
                        // DragGesture's `.onEnded` is this codebase's
                        // established way to get a tap's location (see
                        // CloneStampView's source-point tap).
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleTap(at: value.location, containerSize: geo.size, image: currentImage)
                            }
                    )
                if isDetecting || isProcessingTapPreview {
                    ProgressView().tint(PBColor.accent)
                }
            }
        }
        // Matches the container's own aspect ratio to the image's,
        // instead of a fixed height with `.scaledToFit()` inside — the
        // latter would letterbox for any photo whose aspect ratio doesn't
        // happen to match a fixed box, and `handleTap`'s
        // container-size-to-image-size scale math assumes the displayed
        // image actually fills the whole GeometryReader with no letterbox
        // bars. Same fix InpaintView/CloneStampView already use for their
        // own tap-to-image-coordinate canvases.
        .aspectRatio(currentImage.size, contentMode: .fit)
        .frame(maxHeight: 340)

        Text(detectionResult == nil
            ? "Finding every subject in this photo…"
            : "Tap a subject to cut out just that one.")
            .pbFont(.body)
            .foregroundStyle(PBColor.inkDim)
            .multilineTextAlignment(.center)

        if let tapErrorMessage {
            Text(tapErrorMessage)
                .pbFont(.caption)
                .foregroundStyle(PBColor.bad)
                .multilineTextAlignment(.center)
        }

        if selectedInstance != nil {
            Button {
                Haptics.lightImpact()
                applyTapSelection(from: currentImage)
            } label: {
                Label(isProcessingTapPreview ? "Applying…" : "Cut Out Selected", systemImage: "checkmark")
            }
            .buttonStyle(.pbGradient)
            .disabled(isProcessingTapPreview)
        }
    }

    private func startDetection(_ image: UIImage) {
        guard detectionResult == nil, !isDetecting else { return }
        isDetecting = true
        tapErrorMessage = nil
        Task {
            do {
                detectionResult = try await BackgroundRemovalService.detectInstances(in: image)
                ActionLoggingService.log("cutout_tap_to_select_detect", detail: ["outcome": "success"])
            } catch {
                tapErrorMessage = error.localizedDescription
                ActionLoggingService.log("cutout_tap_to_select_detect", detail: ["outcome": "failed", "error": error.localizedDescription])
            }
            isDetecting = false
        }
    }

    private func handleTap(at location: CGPoint, containerSize: CGSize, image: UIImage) {
        guard let detectionResult, containerSize.width > 0, containerSize.height > 0 else { return }
        Haptics.lightImpact()
        // GeometryReader's coordinate space is the displayed (aspect-fit)
        // frame — scale up to the source image's own pixel space, same
        // "container size -> image size" mapping CloneStampView uses for
        // its own tap-to-image coordinate conversion.
        let scale = image.size.width / containerSize.width
        let imagePoint = CGPoint(x: location.x * scale, y: location.y * scale)
        guard let instance = BackgroundRemovalService.instance(at: imagePoint, in: detectionResult) else {
            tapErrorMessage = "No subject there — try tapping directly on one."
            return
        }
        tapErrorMessage = nil
        selectedInstance = instance
        isProcessingTapPreview = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try? BackgroundRemovalService.cutout(instance, from: detectionResult.cgImage)
            }.value
            tapPreview = result ?? image
            isProcessingTapPreview = false
        }
    }

    private func applyTapSelection(from image: UIImage) {
        guard let selectedInstance, let detectionResult else { return }
        isProcessingTapPreview = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BackgroundRemovalService.cutout(selectedInstance, from: detectionResult.cgImage)
                }.value
                viewModel.resultImage = result
                Haptics.success()
                ActionLoggingService.log("cutout_tap_to_select_apply", detail: ["outcome": "success"])
            } catch {
                tapErrorMessage = error.localizedDescription
                Haptics.error()
                ActionLoggingService.log("cutout_tap_to_select_apply", detail: ["outcome": "failed", "error": error.localizedDescription])
            }
            isProcessingTapPreview = false
        }
    }

    /// Only shown once the current image actually has transparency (a
    /// Cutout result) — a fill behind an opaque photo would just be
    /// invisible. Picking a swatch computes a downscaled preview; Apply
    /// bakes it at full resolution onto the shared result, same as every
    /// other tool's Apply button.
    private var backgroundReplaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(PBColor.inkFaint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(BackgroundFill.allCases) { fill in
                        fillSwatch(fill)
                    }
                }
                .padding(.horizontal, 2)
            }

            if selectedFill != nil {
                HStack(spacing: 10) {
                    Button {
                        Haptics.lightImpact()
                        selectedFill = nil
                        fillPreview = nil
                    } label: {
                        Label("Discard", systemImage: "xmark")
                    }
                    .buttonStyle(.pbGhost)

                    Button {
                        Haptics.lightImpact()
                        applyFill()
                    } label: {
                        Label(isProcessingFill ? "Applying…" : "Apply", systemImage: "checkmark")
                    }
                    .buttonStyle(.pbGradient)
                    .disabled(isProcessingFill)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fillSwatch(_ fill: BackgroundFill) -> some View {
        let isSelected = selectedFill == fill
        let colors = fill.swatchColors
        return Button {
            selectFill(fill)
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(colors.count > 1
                        ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(colors[0]))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().strokeBorder(isSelected ? PBColor.accent : PBColor.line, lineWidth: isSelected ? 2.5 : 1)
                    )
                Text(fill.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? PBColor.accent : PBColor.inkDim)
            }
        }
        .buttonStyle(.plain)
    }

    /// Runs against a downscaled copy for a fast preview — full-resolution
    /// compositing only happens once, in `applyFill()`.
    private func selectFill(_ fill: BackgroundFill) {
        Haptics.lightImpact()
        selectedFill = fill
        guard let currentImage else { return }
        let previewSubject = Self.downscaled(currentImage, maxDimension: 800)
        let previewOriginal = viewModel.sourceImage.map { Self.downscaled($0, maxDimension: 800) }
        isProcessingFill = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BackgroundReplaceService.apply(fill, behind: previewSubject, original: previewOriginal)
            }.value
            fillPreview = result
            isProcessingFill = false
        }
    }

    /// Re-runs at full resolution and writes back to the shared result —
    /// which will itself bump `imageVersion` and clear the fill preview
    /// via the `onChange` above.
    private func applyFill() {
        guard let selectedFill, let currentImage else { return }
        let originalImage = viewModel.sourceImage
        isProcessingFill = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BackgroundReplaceService.apply(selectedFill, behind: currentImage, original: originalImage)
            }.value
            viewModel.resultImage = result
            isProcessingFill = false
        }
    }

    private var emptyState: some View {
        PBEmptyState(icon: "scissors", message: "Choose a photo on the Upscale tab first.")
            .frame(height: 220)
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
    let provider = UpscalerProvider()
    CutoutTabView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
