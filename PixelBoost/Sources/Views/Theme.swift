import SwiftUI

/// Shared dark-canvas visual language for the redesigned UI — a deliberate
/// single-theme commitment (like Halide/Darkroom/Lightroom default dark),
/// not an oversight: PixelBoostApp forces `.dark` colorScheme app-wide so a
/// photo is always the brightest thing on screen. The gradient is reserved
/// for anything the app decided *for* the user (Auto's model pick, primary
/// actions) so it reads as a signal, not decoration.
enum PBColor {
    static let background = Color(red: 0.039, green: 0.047, blue: 0.067)
    static let surface = Color(red: 0.078, green: 0.090, blue: 0.122)
    static let surface2 = Color(red: 0.106, green: 0.122, blue: 0.161)
    static let surface3 = Color(red: 0.137, green: 0.157, blue: 0.220)
    static let line = Color(red: 0.149, green: 0.169, blue: 0.212)
    static let ink = Color(red: 0.953, green: 0.961, blue: 0.976)
    static let inkDim = Color(red: 0.533, green: 0.569, blue: 0.639)
    static let inkFaint = Color(red: 0.337, green: 0.361, blue: 0.420)
    static let accent = Color(red: 0.239, green: 0.545, blue: 1.0)
    static let accent2 = Color(red: 0.545, green: 0.420, blue: 1.0)
    static let good = Color(red: 0.2, green: 0.820, blue: 0.478)
    static let warn = Color(red: 1.0, green: 0.714, blue: 0.282)
    static let bad = Color(red: 1.0, green: 0.361, blue: 0.361)

    static let accentGradient = LinearGradient(
        colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// A rounded, hairline-bordered container standing in for a `Form` section
/// — used everywhere a stock grouped-list section used to be.
struct PBCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(PBColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(PBColor.line, lineWidth: 1)
            )
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
                .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PBColor.ink)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Hairline divider matching `PBCard`'s border color, for separating rows
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
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(PBColor.inkFaint)
            .padding(.horizontal, 4)
    }
}

/// Section explanation — replaces a `Form` section footer.
struct PBFootnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(PBColor.inkFaint)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Full-width gradient pill — the app's one primary-action style (Upscale,
/// Save, Next, Choose Photo when it's the only action on screen).
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(PBColor.accentGradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Secondary/tertiary pill — replaces `.buttonStyle(.bordered)` everywhere.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(PBColor.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(PBColor.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(PBColor.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var pbGradient: GradientButtonStyle { GradientButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var pbGhost: GhostButtonStyle { GhostButtonStyle() }
}
