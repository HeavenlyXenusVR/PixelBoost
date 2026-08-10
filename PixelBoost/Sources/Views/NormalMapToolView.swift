import SwiftUI

/// Flips a normal map between OpenGL convention (Blender's default export)
/// and DirectX convention (most game engines) — see `NormalMapService`.
/// Fixed-effect, one Apply action, same "chain onto whatever's current"
/// pattern as every other tool.
struct NormalMapToolView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var lastBase: UIImage?
    @State private var previewImage: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    ScrollView {
                        VStack(spacing: 24) {
                            PBImageFrame {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 340)
                            }

                            Text("Inverts the green channel — swaps between OpenGL convention (Blender's default normal-map export) and DirectX convention (most game engines expect). Running it twice restores the original.")
                                .pbFont(.caption)
                                .foregroundStyle(PBColor.inkFaint)
                                .multilineTextAlignment(.center)

                            Button {
                                Haptics.lightImpact()
                                apply()
                            } label: {
                                Label("Flip Green Channel", systemImage: "arrow.up.arrow.down")
                            }
                            .buttonStyle(.pbGradient)
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Normal Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
        }
    }

    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewImage = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewImage = current
    }

    private func apply() {
        guard let baseImage = viewModel.resultImage ?? viewModel.sourceImage else { return }
        let flipped = NormalMapService.flipGreenChannel(baseImage)
        viewModel.resultImage = flipped
        Haptics.success()
        ActionLoggingService.log("normal_map_flip")
    }

    private var emptyState: some View {
        PBEmptyState(icon: "arrow.up.arrow.down.square", message: "Choose a photo on the Upscale tab first.")
    }
}

#Preview {
    let provider = UpscalerProvider()
    NormalMapToolView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
