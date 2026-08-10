import Foundation
import SwiftUI

/// Shared dark-canvas visual language for the app — "Aperture": a tactile,
/// photography-studio-inspired redesign of the original flat wireframe-dark
/// UI. Still a deliberate single-theme (dark-only) commitment, like Halide/
/// Darkroom/Lightroom default dark: PixelBoostApp forces `.dark` colorScheme
/// app-wide so a photo is always the brightest thing on screen. Surfaces are
/// layered glass (material + tint + top-edge highlight + shadow) rather than
/// flat fills, and the accent gradient is reserved for exactly one primary
/// action per screen — everywhere else that used to borrow the gradient for
/// emphasis (badges, selected states, borders) uses a solid accent + a soft
/// glow instead, so gradient vs. glow actually means something.
enum PBColor {
    private static let backgroundTop = Color(red: 0.043, green: 0.051, blue: 0.071)
    private static let backgroundBottom = Color(red: 0.086, green: 0.086, blue: 0.106)
    /// A subtle vertical wash instead of a flat fill — still reads as
    /// near-black, just with depth. `LinearGradient` conforms to `View` and
    /// `ShapeStyle` the same way `Color` does, so every existing call site
    /// (`.background(PBColor.background.ignoresSafeArea())`,
    /// `.toolbarBackground(PBColor.background, for:)`) keeps working as-is.
    static let background = LinearGradient(
        colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom
    )
    static let surface = Color(red: 0.078, green: 0.090, blue: 0.122)
    static let surface2 = Color(red: 0.106, green: 0.122, blue: 0.161)
    static let surface3 = Color(red: 0.137, green: 0.157, blue: 0.220)
    static let line = Color(red: 0.149, green: 0.169, blue: 0.212)
    static let ink = Color(red: 0.953, green: 0.961, blue: 0.976)
    static let inkDim = Color(red: 0.533, green: 0.569, blue: 0.639)
    static let inkFaint = Color(red: 0.337, green: 0.361, blue: 0.420)
    /// Reads the user's `AccentTheme` choice once, effectively at launch —
    /// see `AccentTheme`'s doc comment for why this is a `static let`
    /// (evaluated once per process) rather than a live-updating value.
    private static let theme: AccentTheme = UserDefaults.standard.string(forKey: "com.pixelboost.accentTheme")
        .flatMap(AccentTheme.init(rawValue:)) ?? .blue
    static let accent = theme.primary
    static let accent2 = theme.secondary
    static let good = Color(red: 0.2, green: 0.820, blue: 0.478)
    static let warn = Color(red: 1.0, green: 0.714, blue: 0.282)
    static let bad = Color(red: 1.0, green: 0.361, blue: 0.361)

    static let accentGradient = LinearGradient(
        colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// The top-edge "glass" highlight used by every layered surface below —
    /// a hairline that fades from faint white at the top to the ordinary
    /// border color, so cards read as lit from above rather than flat.
    static let glassBorder = LinearGradient(
        colors: [Color.white.opacity(0.09), line], startPoint: .top, endPoint: .bottom
    )
}

/// `RootView`'s bottom tab bar is a plain SwiftUI view pinned on with
/// `.safeAreaInset`, not a real `UITabBarController` — so unlike a native
/// tab bar, UIKit has no idea it's there. Every tab's content sits inside
/// its own `NavigationStack` (see `RootView.tabContent`), and a
/// `NavigationStack` bridges to a real `UINavigationController` under the
/// hood: its safe area is computed by UIKit from actual system chrome
/// (status bar, nav bar, home indicator) and does NOT inherit a SwiftUI
/// ancestor's `.safeAreaInset` from *outside* that UIKit boundary. The
/// result: `List`/`ScrollView` content inside any tab scrolls its last
/// items right under the custom bar instead of stopping above it. Fix is
/// for each tab's own content (inside its `NavigationStack`) to reserve
/// this space itself via `.pbReserveTabBarSpace()`.
enum PBLayout {
    static let bottomBarHeight: CGFloat = 64
}

/// One shared type scale replacing the ad hoc `.font(.system(size:weight:))`
/// literals that used to be hand-picked and repeated at each call site.
enum PBFont {
    case display, title, headline, body, caption, eyebrow

    var font: Font {
        switch self {
        case .display: return .system(size: 26, weight: .heavy)
        case .title: return .system(size: 20, weight: .bold)
        case .headline: return .system(size: 15, weight: .semibold)
        case .body: return .system(size: 13, weight: .regular)
        case .caption: return .system(size: 11.5, weight: .medium)
        case .eyebrow: return .system(size: 10, weight: .bold)
        }
    }

    var tracking: CGFloat {
        self == .eyebrow ? 0.6 : 0
    }
}

extension View {
    func pbFont(_ style: PBFont) -> some View {
        font(style.font).tracking(style.tracking)
    }

    /// Layered "glass" surface: translucent material + a dark tint (so it
    /// still reads as part of the dark canvas, not a frosted light panel) +
    /// the shared top-edge highlight border + a soft contact shadow. Used by
    /// `PBCard` and the secondary list-item-card idiom (`BatchItemCard`,
    /// `CloudCard`, `HistoryCard`) alike, so both card families share one
    /// surface language even though they don't share a struct.
    func pbGlassSurface(cornerRadius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(PBColor.surface.opacity(0.62)))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PBColor.glassBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 7)
    }

    /// Solid accent fill + soft glow — the "signal" replacement for
    /// everywhere the accent *gradient* used to be borrowed for badges/
    /// selected chips. Expects `self` to already be padded/shaped text.
    func pbAccentGlow(cornerRadius: CGFloat = 999) -> some View {
        foregroundStyle(.white)
            .background(PBColor.accent, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: PBColor.accent.opacity(0.5), radius: 8, x: 0, y: 3)
    }

    /// Same signal, as a border+glow instead of a fill — for selected-state
    /// cards (the chosen model in `ModelPickerView`, the winning result in
    /// `ModelComparisonView`) where the card keeps its own glass fill.
    func pbAccentGlowBorder(cornerRadius: CGFloat, lineWidth: CGFloat = 1.5) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PBColor.accent, lineWidth: lineWidth)
        )
        .shadow(color: PBColor.accent.opacity(0.32), radius: 12, x: 0, y: 0)
    }

    /// Reserves space for `RootView`'s custom bottom tab bar — see
    /// `PBLayout` doc comment for why this can't just be inherited from an
    /// ancestor `.safeAreaInset`. Apply to the scrollable content INSIDE
    /// each tab's own `NavigationStack` (e.g. the `ScrollView`/`List`/`Form`
    /// itself), not to the `NavigationStack` from outside.
    func pbReserveTabBarSpace() -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: PBLayout.bottomBarHeight)
        }
    }
}

/// A rounded, glass-surfaced container standing in for a `Form` section —
/// used everywhere a stock grouped-list section used to be.
struct PBCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .pbGlassSurface(cornerRadius: 20)
    }
}

/// One icon-led row inside a `PBCard` — the card equivalent of a plain
/// `LabeledContent`/`Picker` row in a `Form`.
struct PBCardRow: View {
    let icon: String
    var iconTint: Color = PBColor.accent
    let label: String
    var value: String?
    var valueTint: Color = PBColor.inkDim

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 30, height: 30)
                .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
            Text(label)
                .pbFont(.headline)
                .foregroundStyle(PBColor.ink)
            Spacer()
            if let value {
                Text(value)
                    .pbFont(.body)
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Hairline divider matching the card border color, for separating rows
/// within one card (rows don't own their own bottom border, unlike the
/// mockup's CSS — SwiftUI has no per-child `border-bottom` shorthand).
struct PBRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(PBColor.line)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

/// Section eyebrow label — replaces a `Form` section header.
struct PBSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .pbFont(.eyebrow)
            .foregroundStyle(PBColor.inkFaint)
            .padding(.horizontal, 4)
    }
}

/// Section explanation — replaces a `Form` section footer.
struct PBFootnote: View {
    let text: String
    var body: some View {
        Text(text)
            .pbFont(.caption)
            .foregroundStyle(PBColor.inkFaint)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Wraps a photo preview (an `Image`, or a `ZStack` with overlay chrome on
/// top of one) in the "print on a mat" treatment — a soft highlight border
/// and a real contact shadow — instead of a bare clipped rectangle. Used by
/// every tool tab's main image preview.
struct PBImageFrame<Content: View>: View {
    var cornerRadius: CGFloat = 20
    let content: Content

    init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
    }
}

/// One shared "nothing here yet" formula — icon in a soft glass badge,
/// optional title, message — replacing the ad hoc icon+text empty states
/// duplicated across most editor tabs and the data-driven list screens.
struct PBEmptyState: View {
    let icon: String
    var title: String?
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(PBColor.inkFaint)
                .frame(width: 64, height: 64)
                .pbGlassSurface(cornerRadius: 32)
            if let title {
                Text(title)
                    .pbFont(.headline)
                    .foregroundStyle(PBColor.ink)
            }
            Text(message)
                .pbFont(.body)
                .foregroundStyle(PBColor.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-width gradient pill — the app's one primary-action style (Upscale,
/// Save, Next, Choose Photo when it's the only action on screen). Now with
/// an inner highlight and a real accent-tinted contact shadow that presses
/// flat on tap, instead of just a flat opacity/scale tap response.
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(PBColor.accentGradient, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(configuration.isPressed ? 0.08 : 0.22), lineWidth: 1)
            )
            .shadow(
                color: PBColor.accent.opacity(configuration.isPressed ? 0.15 : 0.45),
                radius: configuration.isPressed ? 4 : 16, x: 0, y: configuration.isPressed ? 2 : 8
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Secondary/tertiary pill — replaces `.buttonStyle(.bordered)` everywhere.
/// Moved to the same glass-surface language as `PBCard` instead of a flat
/// `surface2` fill, so primary/secondary actions read as "gradient signal"
/// vs. "glass surface" rather than "gradient" vs. "flat gray".
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(PBColor.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .background(PBColor.surface2.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(PBColor.glassBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var pbGradient: GradientButtonStyle { GradientButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var pbGhost: GhostButtonStyle { GhostButtonStyle() }
}
