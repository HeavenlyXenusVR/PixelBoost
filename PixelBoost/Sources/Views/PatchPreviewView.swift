import SwiftUI

/// Try before you commit: drag the square over the part of the photo you
/// care about (a face, text, fine texture), and every candidate model
/// upscales just that patch — seconds instead of minutes, a handful of
/// tiles instead of a thousand. Pick the one that looks right and it
/// becomes the model for the full run.
struct PatchPreviewView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @EnvironmentObject private var provider: UpscalerProvider
    @Environment(\.dismiss) private var dismiss

    let display: UIImage
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var before: UIImage?
    @State private var results: [PatchPreviewResult] = []
    @State private var failed = false

    private static let patchSide = 160

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    navigator
                    Button {
                        Task { await run() }
                    } label: {
                        Label(viewModel.isPreviewingPatch ? "Upscaling patch…" : "Preview This Patch", systemImage: "square.dashed.inset.filled")
                    }
                    .buttonStyle(.pbGradient)
                    .disabled(viewModel.isPreviewingPatch)

                    if failed {
                        PBFootnote(text: "Couldn't upscale this patch. Try another spot.")
                    }

                    if let before, !results.isEmpty {
                        PBSectionLabel(title: "Results at \(provider.scaleFactor.displayName) · \(provider.fidelity.displayName) fidelity")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            card(title: "Original", subtitle: "nearest-neighbor", image: before, pixelated: true, choice: nil, selectable: false)
                            ForEach(results) { result in
                                card(
                                    title: result.title,
                                    subtitle: result.fidelityPSNR.map { String(format: "fidelity %.1f dB", $0) } ?? "",
                                    image: result.image, pixelated: false,
                                    choice: result.choice, selectable: result.choice != nil
                                )
                            }
                        }
                        PBFootnote(text: "Higher fidelity means the upscale, shrunk back down, matches your original more closely. Tap a model to use it for the full upscale.")
                    }
                }
                .padding(PBLayout.gutter)
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Patch Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var navigator: some View {
        GeometryReader { geo in
            let size = geo.size
            let pixelWidth = CGFloat((viewModel.resultImage ?? viewModel.sourceImage)?.cgImage?.width ?? 1)
            let side = max(24, size.width * CGFloat(Self.patchSide) / pixelWidth)
            ZStack(alignment: .topLeading) {
                Image(uiImage: display)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                Rectangle()
                    .strokeBorder(PBColor.accent, lineWidth: 2)
                    .background(Rectangle().fill(PBColor.accent.opacity(0.12)))
                    .frame(width: side, height: side)
                    .position(x: center.x * size.width, y: center.y * size.height)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    center = CGPoint(
                        x: min(1, max(0, value.location.x / max(1, size.width))),
                        y: min(1, max(0, value.location.y / max(1, size.height)))
                    )
                }
            )
        }
        .aspectRatio(display.size.width / max(1, display.size.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PBColor.lineStrong, lineWidth: 1))
        .frame(maxHeight: 300)
    }

    private func card(title: String, subtitle: String, image: UIImage, pixelated: Bool, choice: UpscaleModelChoice?, selectable: Bool) -> some View {
        let isSelected = choice != nil && choice == provider.modelChoice
        return Button {
            guard selectable, let choice else { return }
            Haptics.lightImpact()
            provider.modelChoice = choice
            ActionLoggingService.log("patch_preview_pick", detail: ["model": choice.rawValue])
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(pixelated ? .none : .high)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .pbFont(.monoSmall)
                    .foregroundStyle(PBColor.inkDim)
                    .lineLimit(1)
            }
            .padding(8)
            .pbGlassSurface(cornerRadius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? PBColor.accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }

    private func run() async {
        failed = false
        Haptics.lightImpact()
        if let preview = await viewModel.previewPatch(at: center, side: Self.patchSide) {
            before = preview.before
            results = preview.results
            Haptics.success()
        } else {
            failed = true
            Haptics.error()
        }
    }
}
