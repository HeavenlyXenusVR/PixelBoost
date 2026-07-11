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
            title: "Pick, Test, Upscale",
            message: "Choose a photo and Auto quietly tests it against every bundled model, then upscales with whichever looks sharpest. Prefer to choose yourself? General Photo and Anime/Illustration models are one tap away."
        ),
        OnboardingPage(
            systemImage: "icloud",
            title: "Cloud Features Are Optional",
            message: "Batch upscale, history, and cloud backup all work fully offline by default. Set a server URL in Settings only if you want debug logging, temporary cloud storage, or custom presets synced."
        ),
    ]

    var body: some View {
        ZStack {
            PBColor.background.ignoresSafeArea()
            RadialGradient(
                colors: [PBColor.accent2.opacity(0.22), .clear],
                center: UnitPoint(x: 0.5, y: 0.05), startRadius: 20, endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        OnboardingPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? AnyShapeStyle(PBColor.accentGradient) : AnyShapeStyle(PBColor.surface3))
                            .frame(width: index == page ? 18 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: page)
                    }
                }
                .padding(.bottom, 18)

                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Next" : "Get Started")
                }
                .buttonStyle(.pbGradient)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.dark)
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
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(PBColor.accentGradient)
                    .frame(width: 84, height: 84)
                    .shadow(color: PBColor.accent2.opacity(0.45), radius: 24, y: 10)
                Image(systemName: page.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(page.title)
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(PBColor.ink)
            Text(page.message)
                .font(.system(size: 14.5))
                .foregroundStyle(PBColor.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
                .lineSpacing(3)
            Spacer()
            Spacer()
        }
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
