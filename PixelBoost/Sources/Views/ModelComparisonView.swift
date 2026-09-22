import SwiftUI

/// Shows every `ModelComparisonResult` from `UpscalerViewModel.compareModels()`
/// as a full-image, tappable grid — the point is to actually look at each
/// model's real output on the real photo (not a proxy score) before
/// deciding. Tapping a card opens it full-screen via `ZoomableImageView`;
/// "Use This" from either place picks it as the result and dismisses.
struct ModelComparisonView: View {
    let results: [ModelComparisonResult]
    let onPick: (ModelComparisonResult) -> Void
    let onSaveAll: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zoomedResult: ModelComparisonResult?

    private var bestScore: Double {
        results.map(\.sharpnessScore).max() ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Every bundled model ran on your full photo — tap one to view it full-screen, then use whichever looks best to you.")
                        .pbFont(.body)
                        .foregroundStyle(PBColor.inkDim)
                        .padding(.horizontal, 2)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(results) { result in
                            ComparisonCard(
                                result: result, isSharpest: result.sharpnessScore == bestScore,
                                onTapImage: { zoomedResult = result },
                                onUseThis: { onPick(result); dismiss() }
                            )
                        }
                    }
                }
                .padding(16)
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Compare Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSaveAll()
                    } label: {
                        Label("Save All", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { zoomedResult != nil },
                set: { isPresented in if !isPresented { zoomedResult = nil } }
            )) {
                if let zoomedResult {
                    ZStack(alignment: .bottom) {
                        ZoomableImageView(image: zoomedResult.image)
                        Button {
                            onPick(zoomedResult)
                            dismiss()
                        } label: {
                            Label("Use This — \(zoomedResult.choice.displayName)", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.pbGradient)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
    }
}

private struct ComparisonCard: View {
    let result: ModelComparisonResult
    let isSharpest: Bool
    let onTapImage: () -> Void
    let onUseThis: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PBImageFrame(cornerRadius: 14) {
                Image(uiImage: result.image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(6)
                    }
                    .onTapGesture(perform: onTapImage)
            }

            HStack(spacing: 6) {
                Text(result.choice.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PBColor.ink)
                    .lineLimit(1)
                if isSharpest {
                    Text("SHARPEST")
                        .font(.system(size: 8.5, weight: .heavy))
                        .tracking(0.2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .pbAccentGlow(cornerRadius: 4)
                }
            }
            Text("Sharpness \(String(format: "%.2f", result.sharpnessScore))")
                .pbFont(.caption)
                .foregroundStyle(PBColor.inkFaint)

            Button(action: onUseThis) {
                Text("Use This")
            }
            .buttonStyle(.pbGhost)
        }
        .padding(10)
        .pbGlassSurface(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSharpest ? PBColor.accent : .clear, lineWidth: 1.5)
        )
        .shadow(color: isSharpest ? PBColor.accent.opacity(0.3) : .clear, radius: 10, x: 0, y: 0)
    }
}
