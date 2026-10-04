import SwiftUI

/// Three modes: "Everything" (the original, still-default behavior — a
/// single unattended action cutting out every detected subject at once),
/// "Tap to Select" (pick one specific subject by tapping it — see
/// `BackgroundRemovalService`'s "Tap to Select" section), and "Touch Up"
/// (brush the result by hand where Vision got it wrong — see
/// `CutoutRefineService`). Writes straight to `viewModel.resultImage`,
/// same as every other tool.
private enum CutoutMode: String, CaseIterable, Identifiable {
    case auto, tapToSelect, touchUp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Everything"
        case .tapToSelect: return "Tap to Select"
        case .touchUp: return "Touch Up"
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

    // Touch Up — manual brush repair of a cutout Vision got wrong. Same
    // stroke/mask plumbing as Erase and Selective Adjustments
    // (`BrushStroke`/`BrushMask`), with a polarity picker for whether a
    // stroke restores the original's pixels or clears to transparent.
    @State private var touchUpBrush: CutoutRefineService.Brush = .restore
    @State private var strokes: [BrushStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var brushSize: CGFloat = 36
    @State private var canvasSize: CGSize = .zero
    @State private var isRefining = false
    @State private var touchUpErrorMessage: String?

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
                            clearStrokes()
                            ActionLoggingService.log("cutout_mode", detail: ["mode": newMode.rawValue])
                        }

                        switch mode {
                        case .auto: autoModeContent(currentImage)
                        case .tapToSelect: tapToSelectContent(currentImage)
                        case .touchUp: touchUpContent(currentImage)
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
            .pbScreen("Cutout")
            .pbRefresh(on: viewModel.imageVersion) {
                selectedFill = nil
                fillPreview = nil
                detectionResult = nil
                selectedInstance = nil
                tapPreview = nil
                tapErrorMessage = nil
                clearStrokes()
                touchUpErrorMessage = nil
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

    /// Hand repair for a cutout the Vision matte got wrong — paint to
    /// bring the original photo's pixels back (a clipped arm, a strand of
    /// hair) or to clear background it wrongly kept. Only useful on an
    /// image that actually has transparency, so on an opaque photo this
    /// says so rather than offering a brush whose every stroke would be a
    /// no-op.
    @ViewBuilder
    private func touchUpContent(_ currentImage: UIImage) -> some View {
        if !currentImage.hasAlphaChannel {
            VStack(spacing: 10) {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PBColor.inkFaint)
                Text("Nothing to touch up yet — run Remove Background or Tap to Select first, then come back here to fix anything it got wrong.")
                    .pbFont(.body)
                    .foregroundStyle(PBColor.inkDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 40)
        } else {
            PBImageFrame {
                GeometryReader { geo in
                    // `PBImageFrame` already lays a transparency
                    // checkerboard under its content, so a region the
                    // brush clears reads as transparent rather than as
                    // whatever the surface color happens to be.
                    ZStack {
                        Image(uiImage: currentImage)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)

                        Canvas { context, _ in
                            for stroke in strokes {
                                drawStroke(stroke.points, brushSize: stroke.brushSize, in: &context)
                            }
                            if !currentPoints.isEmpty {
                                drawStroke(currentPoints, brushSize: brushSize, in: &context)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(!isRefining)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in currentPoints.append(value.location) }
                            .onEnded { _ in
                                if !currentPoints.isEmpty {
                                    strokes.append(BrushStroke(points: currentPoints, brushSize: brushSize))
                                }
                                currentPoints = []
                            }
                    )
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
                }
            }
            // Container matched to the image's own aspect ratio, so
            // `BrushMask`'s single uniform canvas-to-pixel scale factor
            // holds with no letterboxing to correct for — the same
            // requirement InpaintView's canvas has.
            .aspectRatio(currentImage.size, contentMode: .fit)
            .frame(maxHeight: 340)

            Picker("Brush", selection: $touchUpBrush) {
                Text("Restore").tag(CutoutRefineService.Brush.restore)
                Text("Erase").tag(CutoutRefineService.Brush.erase)
            }
            .pickerStyle(.segmented)
            .disabled(isRefining)

            Text(touchUpBrush == .restore
                ? "Paint over a part of the subject the cutout wrongly removed to bring it back from the original photo."
                : "Paint over background the cutout wrongly kept to clear it to transparent.")
                .pbFont(.caption)
                .foregroundStyle(PBColor.inkFaint)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                Text("Brush Size")
                    .pbFont(.eyebrow)
                    .foregroundStyle(PBColor.inkFaint)
                Slider(value: $brushSize, in: 12...80)
                    .tint(PBColor.accent)
                    .disabled(isRefining)
            }

            HStack(spacing: 10) {
                Button {
                    Haptics.lightImpact()
                    strokes.removeLast()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.pbGhost)
                .disabled(strokes.isEmpty || isRefining)

                Button {
                    Haptics.lightImpact()
                    clearStrokes()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.pbGhost)
                .disabled(strokes.isEmpty || isRefining)
            }

            Button {
                Haptics.lightImpact()
                applyTouchUp(to: currentImage)
            } label: {
                Label(isRefining ? "Applying…" : "Apply Brush", systemImage: "checkmark")
            }
            .buttonStyle(.pbGradient)
            .disabled(strokes.isEmpty || isRefining)

            if let touchUpErrorMessage {
                Text(touchUpErrorMessage)
                    .pbFont(.caption)
                    .foregroundStyle(PBColor.bad)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func drawStroke(_ points: [CGPoint], brushSize: CGFloat, in context: inout GraphicsContext) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        // Green for restore, red for erase — the stroke overlay should say
        // which direction it is going to push, since the two are painted
        // identically otherwise.
        context.stroke(
            path,
            with: .color((touchUpBrush == .restore ? Color.green : Color.red).opacity(0.45)),
            style: StrokeStyle(lineWidth: brushSize, lineCap: .round, lineJoin: .round)
        )
    }

    private func clearStrokes() {
        strokes = []
        currentPoints = []
    }

    /// Rasterizes the painted strokes and composites them onto the current
    /// cutout. Writing to `viewModel.resultImage` bumps `imageVersion`,
    /// which clears the strokes via `pbRefresh` — they are baked in by
    /// then, same as Erase.
    private func applyTouchUp(to currentImage: UIImage) {
        guard !strokes.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let mask = BrushMask.rasterize(strokes, canvasSize: canvasSize, pixelSize: currentImage.size)
        let original = viewModel.sourceImage
        let brush = touchUpBrush
        let strokeCount = strokes.count
        isRefining = true
        touchUpErrorMessage = nil
        let startedAt = Date()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CutoutRefineService.refine(currentImage, original: original, mask: mask, brush: brush)
            }.value
            let durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let result {
                viewModel.resultImage = result
                Haptics.success()
                ActionLoggingService.log(
                    "cutout_touch_up",
                    detail: [
                        "brush": brush == .restore ? "restore" : "erase",
                        "strokes": strokeCount,
                        "brush_size": Double(brushSize),
                        "had_original": original != nil,
                    ],
                    outcome: "success",
                    durationMS: durationMS
                )
            } else {
                // The one expected failure is Restore with no original to
                // read from — say that specifically instead of a generic
                // "didn't work", since it is the user's situation to fix.
                touchUpErrorMessage = brush == .restore && original == nil
                    ? "The original photo isn't available to restore from — reload the photo and try again."
                    : "Couldn't apply the brush to this image."
                Haptics.error()
                ActionLoggingService.log(
                    "cutout_touch_up",
                    detail: [
                        "brush": brush == .restore ? "restore" : "erase",
                        "strokes": strokeCount,
                        "had_original": original != nil,
                    ],
                    outcome: "failed",
                    durationMS: durationMS
                )
            }
            isRefining = false
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
        PBNoPhotoState(tab: .cutout)
            .frame(minHeight: 420)
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
