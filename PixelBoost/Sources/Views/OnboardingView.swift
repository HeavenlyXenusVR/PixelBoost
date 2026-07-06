import SwiftUI

/// First-launch introduction, shown once via `hasSeenOnboarding`
/// (@AppStorage) — explains what the app does and that server features are
/// optional before the user runs into the Photo Library permission prompt
/// or the Settings server fields cold.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "sparkles",
            title: "PixelBoost",
            message: "Turn blurry or low-resolution photos into sharp, higher-resolution images using an on-device AI model — nothing ever leaves your phone unless you choose to back it up."
        ),
        OnboardingPage(
            systemImage: "wand.and.stars",
            title: "Pick, Upscale, Compare",
            message: "Choose a photo, tap Upscale, then drag the before/after slider to see the difference. Switch between a General Photo model and an Anime/Illustration model in Settings, and trade speed for quality with Fast/Standard/Best."
        ),
        OnboardingPage(
            systemImage: "icloud",
            title: "Cloud Features Are Optional",
            message: "Batch upscale, history, and cloud backup all work fully offline by default. Set a server URL in Settings only if you want debug logging, temporary cloud storage, or custom presets synced."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: page.systemImage)
                .font(.system(size: 64))
                .foregroundStyle(AccentColorProxy.color)
            Text(page.title)
                .font(.title2.weight(.bold))
            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}

/// `Color("AccentColor")` needs the asset catalog name explicitly — SwiftUI's
/// `.tint`/implicit accent isn't guaranteed to resolve the same way inside a
/// plain `Image.foregroundStyle` outside of controls.
private enum AccentColorProxy {
    static let color = Color("AccentColor")
}

#Preview {
    OnboardingView(onFinish: {})
}
