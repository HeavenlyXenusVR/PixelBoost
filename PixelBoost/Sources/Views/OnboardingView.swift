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
            systemImage: nil,
            title: "Every pixel, upscaled",
            message: "PixelBoost runs your whole photo through an on-device AI model at full resolution — tile by tile, pixel by pixel. Nothing is shrunk first, and nothing leaves your phone unless you choose to back it up."
        ),
        OnboardingPage(
            systemImage: "square.grid.3x3.middle.filled",
            title: "Watch it work",
            message: "See finished tiles fill in live, pause any time to let the phone cool, and check the result pixel-for-pixel against the original in the Pixel Inspector."
        ),
        OnboardingPage(
            systemImage: "leaf",
            title: "Easy on the battery",
            message: "Pick a Power mode: Efficiency keeps work on the Neural Engine and paces itself as the phone warms. Low Power Mode switches to it automatically."
        ),
        OnboardingPage(
            systemImage: "square.grid.2x2",
            title: "A full editor, too",
            message: "Twenty tools — cutout, restore, filters, frames, textures and more — all editing one shared photo, with undo across every edit."
        ),
    ]

    var body: some View {
        ZStack {
            PBColor.background.ignoresSafeArea()

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
                            .fill(index == page ? AnyShapeStyle(PBColor.accent) : AnyShapeStyle(PBColor.surface3))
                            .frame(width: index == page ? 18 : 6, height: 6)
                            .animation(PBMotion.isReduced ? nil : .easeInOut(duration: 0.2), value: page)
                    }
                }
                .padding(.bottom, 18)

                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        ActionLoggingService.log("onboarding_finish", detail: [
                            "page_count": pages.count,
                        ], outcome: "success")
                        // The app may go straight to work after this, and
                        // a first-launch buffer that never flushes is the
                        // one case where these events are most likely to
                        // be lost.
                        TelemetryService.flush()
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
        // Which page a first launch reaches is the only drop-off signal
        // this app has, and it was not recorded anywhere — an onboarding
        // that loses people on page 2 looked identical in the log to one
        // everybody finished. Logged on change rather than only at
        // "Get Started" precisely because the interesting case is the run
        // that never gets there.
        .onAppear {
            ActionLoggingService.log("onboarding_page", detail: [
                "page": 0, "page_count": pages.count, "furthest": true,
            ])
        }
        .onChange(of: page) { oldPage, newPage in
            ActionLoggingService.log("onboarding_page", detail: [
                "page": newPage,
                "page_count": pages.count,
                // A swipe back is a different event from reaching a page
                // for the first time; without this, re-reading page 1
                // would inflate the furthest-reached count.
                "furthest": newPage > oldPage,
            ])
        }
    }
}

private struct OnboardingPage {
    /// nil shows the app's pixel mark instead of a symbol.
    let systemImage: String?
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Group {
                if let systemImage = page.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(PBColor.accent)
                        .frame(width: 84, height: 84)
                        .background(PBColor.accentSoft, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    PixelMark().frame(width: 84, height: 84)
                }
            }
            Text(page.title)
                .pbFont(.display)
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
