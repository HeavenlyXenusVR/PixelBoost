import SwiftUI

/// Sheet for choosing the upscale model — replaces the old inline Settings
/// `Picker` now that there are 6 options instead of 2 (see
/// `UpscaleModelChoice`). Auto is pinned to the top and marked recommended;
/// not-yet-bundled models are shown honestly rather than hidden, matching
/// the app's existing "not bundled" degrade-to-Lanczos behavior.
struct ModelPickerView: View {
    @ObservedObject var provider: UpscalerProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(UpscaleModelChoice.allCases) { choice in
                        ModelCard(choice: choice, isSelected: provider.modelChoice == choice) {
                            provider.modelChoice = choice
                            Haptics.lightImpact()
                            dismiss()
                        }
                    }

                    PBFootnote(
                        text: "Auto and the two starred models above are real, on-device Core ML "
                            + "models. The rest are on the roadmap — picking one today falls back "
                            + "to plain resampling, same as any missing model always has."
                    )
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Choose a Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ModelCard: View {
    let choice: UpscaleModelChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(choice.displayName)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(PBColor.ink)
                        badge
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(PBColor.inkDim)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(PBColor.accentGradient, in: Circle())
                }
            }
            .padding(13)
            .background(PBColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(PBColor.accentGradient) : AnyShapeStyle(PBColor.line),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .opacity(choice == .auto || choice.isBundled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var badge: some View {
        if choice == .auto {
            Text("RECOMMENDED")
                .font(.system(size: 9.5, weight: .heavy))
                .tracking(0.3)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PBColor.accentGradient, in: RoundedRectangle(cornerRadius: 5))
        } else if !choice.isBundled {
            Text("NOT BUNDLED")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.2)
                .foregroundStyle(PBColor.inkFaint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PBColor.surface3, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(choice == .auto ? .white : PBColor.inkDim)
            .frame(width: 40, height: 40)
            .background(
                choice == .auto ? AnyShapeStyle(PBColor.accentGradient) : AnyShapeStyle(PBColor.surface2),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    private var systemImage: String {
        switch choice {
        case .auto: return "sparkles"
        case .generalPhoto: return "photo"
        case .anime: return "paintpalette"
        case .portrait: return "person.crop.square"
        case .lowLight: return "moon.stars"
        case .textDocument: return "doc.text"
        }
    }

    private var subtitle: String {
        switch choice {
        case .auto: return "Tests your photo, keeps the sharper result"
        case .generalPhoto: return "Real-ESRGAN x4plus"
        case .anime: return "Real-ESRGAN anime_6B"
        case .portrait: return "Faces & skin detail"
        case .lowLight: return "Noise-aware denoising"
        case .textDocument: return "Crisp edges on type"
        }
    }
}

#Preview {
    ModelPickerView(provider: UpscalerProvider())
}
