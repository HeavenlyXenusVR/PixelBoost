import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// "Darkroom" — PixelBoost's visual language.
///
/// A flat graphite canvas where the photo is always the brightest thing on
/// screen. It replaces the earlier "Aperture" glass look, and the change is
/// as much about battery as taste:
///
/// - **No live blur.** `.ultraThinMaterial` re-samples and blurs whatever
///   sits behind it on every frame that content moves (every scroll, every
///   slider drag). Surfaces here are solid fills with a hairline edge,
///   which the compositor draws once and caches.
/// - **Shadows only where depth means something** (the floating dock and
///   the photo itself), never on every card — each blurred shadow is an
///   offscreen render pass.
/// - **Motion is gated** (`PBMotion`): springs and transitions turn off in
///   Low Power Mode and with Reduce Motion.
/// - **Numbers are monospaced.** Pixel counts, sizes and timings line up
///   and stop jittering while they tick.
///
/// Still a deliberate dark-only commitment — `PixelBoostApp` forces `.dark`.
enum PBColor {
    static let background = Color(red: 0.039, green: 0.043, blue: 0.051)
    static let surface = Color(red: 0.075, green: 0.082, blue: 0.098)
    static let surface2 = Color(red: 0.106, green: 0.114, blue: 0.137)
    static let surface3 = Color(red: 0.145, green: 0.157, blue: 0.188)
    static let line = Color.white.opacity(0.07)
    static let lineStrong = Color.white.opacity(0.13)
    static let ink = Color(red: 0.957, green: 0.961, blue: 0.969)
    static let inkDim = Color(red: 0.600, green: 0.620, blue: 0.667)
    static let inkFaint = Color(red: 0.400, green: 0.420, blue: 0.467)

    /// Read once at launch — see `AccentTheme` for why it isn't live.
    private static let theme: AccentTheme = UserDefaults.standard.string(forKey: "com.pixelboost.accentTheme")
        .flatMap(AccentTheme.init(rawValue:)) ?? .blue
    static let accent = theme.primary
    static let accent2 = theme.secondary
    static let accentSoft = theme.primary.opacity(0.16)
    static let good = Color(red: 0.247, green: 0.839, blue: 0.537)
    static let warn = Color(red: 1.0, green: 0.725, blue: 0.302)
    static let bad = Color(red: 1.0, green: 0.400, blue: 0.400)

    /// Reserved for the one primary action per screen.
    static let accentGradient = LinearGradient(
        colors: [accent, accent2], startPoint: .leading, endPoint: .trailing
    )

    /// Kept for call sites from the glass era; now just the hairline.
    static let glassBorder = LinearGradient(colors: [lineStrong, line], startPoint: .top, endPoint: .bottom)
}

/// Motion that switches itself off when the user (or the battery) asks.
enum PBMotion {
    static var isReduced: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibility.isReduceMotionEnabled
    }

    static var snappy: Animation? {
        isReduced ? nil : .spring(response: 0.28, dampingFraction: 0.82)
    }
}

enum PBLayout {
    /// Height reserved under scrollable content for the floating dock
    /// (dock + its bottom margin). See `pbReserveTabBarSpace()`.
    static let bottomBarHeight: CGFloat = 84
    static let gutter: CGFloat = 16
}

/// One shared type scale.
enum PBFont {
    case display, title, headline, body, caption, eyebrow, mono, monoSmall

    var font: Font {
        switch self {
        case .display: return .system(size: 30, weight: .bold, design: .rounded)
        case .title: return .system(size: 20, weight: .bold, design: .rounded)
        case .headline: return .system(size: 15, weight: .semibold)
        case .body: return .system(size: 13.5, weight: .regular)
        case .caption: return .system(size: 11.5, weight: .medium)
        case .eyebrow: return .system(size: 10.5, weight: .bold)
        case .mono: return .system(size: 13, weight: .semibold, design: .monospaced)
        case .monoSmall: return .system(size: 10.5, weight: .medium, design: .monospaced)
        }
    }

    var tracking: CGFloat {
        self == .eyebrow ? 1.1 : 0
    }
}

extension View {
    func pbFont(_ style: PBFont) -> some View {
        font(style.font).tracking(style.tracking)
    }

    /// Flat elevated surface: solid fill + hairline. (Name kept from the
    /// glass era so every screen picked up the new look in one place.)
    func pbGlassSurface(cornerRadius: CGFloat) -> some View {
        background(PBColor.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PBColor.line, lineWidth: 1)
            )
    }

    /// Solid accent pill for badges and selected chips.
    func pbAccentGlow(cornerRadius: CGFloat = 999) -> some View {
        foregroundStyle(.white)
            .background(PBColor.accent, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Selected-state outline for cards that keep their own fill.
    func pbAccentGlowBorder(cornerRadius: CGFloat, lineWidth: CGFloat = 1.5) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PBColor.accent, lineWidth: lineWidth)
        )
    }

    /// Reserves space for `RootView`'s floating dock. `NavigationStack`
    /// computes its own safe area from real UIKit chrome and won't inherit
    /// an ancestor's `.safeAreaInset`, so each tab's scroll content applies
    /// this itself.
    func pbReserveTabBarSpace() -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: PBLayout.bottomBarHeight)
        }
    }

    /// The shared chrome every screen uses: background, inline title,
    /// opaque bar, dock clearance, and — on editing screens — the global
    /// undo/redo buttons plus a way back to the tool library.
    func pbScreen(_ title: String, tool: Bool = true) -> some View {
        modifier(PBScreenChrome(title: title, showsToolControls: tool))
    }
}

/// Lets a tool screen jump back to the Tools library without knowing how
/// `RootView` is wired.
private struct PBShowToolsKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

/// True only for the tab currently on screen. Tabs stay mounted for state
/// preservation, so expensive refresh work checks this first.
private struct PBIsActiveTabKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var pbShowTools: (() -> Void)? {
        get { self[PBShowToolsKey.self] }
        set { self[PBShowToolsKey.self] = newValue }
    }

    var pbIsActiveTab: Bool {
        get { self[PBIsActiveTabKey.self] }
        set { self[PBIsActiveTabKey.self] = newValue }
    }
}

private struct PBScreenChrome: ViewModifier {
    let title: String
    let showsToolControls: Bool
    @Environment(\.pbShowTools) private var showTools

    func body(content: Content) -> some View {
        content
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if showsToolControls {
                    if let showTools {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                Haptics.lightImpact()
                                showTools()
                            } label: {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .accessibilityLabel("All Tools")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        PBUndoRedoButtons()
                    }
                }
            }
    }
}

/// Global undo/redo over every edit to the current photo.
struct PBUndoRedoButtons: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    var body: some View {
        HStack(spacing: 2) {
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo || viewModel.isBusy)
            .accessibilityLabel("Undo")
            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo || viewModel.isBusy)
            .accessibilityLabel("Redo")
        }
        .font(.system(size: 14, weight: .semibold))
        .tint(PBColor.ink)
    }
}

/// Grouped container standing in for a `Form` section.
struct PBCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .pbGlassSurface(cornerRadius: 18)
    }
}

/// One icon-led row inside a `PBCard`.
struct PBCardRow: View {
    let icon: String
    var iconTint: Color = PBColor.accent
    let label: String
    var value: String?
    var valueTint: Color = PBColor.inkDim

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(label)
                .pbFont(.headline)
                .foregroundStyle(PBColor.ink)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .pbFont(.body)
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct PBRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(PBColor.line)
            .frame(height: 1)
            .padding(.leading, 54)
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
            .padding(.top, 6)
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

/// The photo "on the light table": a checkerboard under it (so a cutout's
/// transparency is visible, not black), a hairline, and the app's one
/// real shadow.
struct PBImageFrame<Content: View>: View {
    var cornerRadius: CGFloat = 18
    let content: Content

    init(cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background(PBCheckerboard())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PBColor.lineStrong, lineWidth: 1)
            )
    }
}

/// Transparency checkerboard, drawn once with `Canvas` (no per-square views).
struct PBCheckerboard: View {
    var square: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PBColor.surface2))
            var path = Path()
            let columns = Int(size.width / square) + 1
            let rows = Int(size.height / square) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(PBColor.surface3))
        }
        .allowsHitTesting(false)
    }
}

/// One shared "nothing here yet" formula.
struct PBEmptyState: View {
    let icon: String
    var title: String?
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(PBColor.accent)
                .frame(width: 60, height: 60)
                .background(PBColor.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if let title {
                Text(title)
                    .pbFont(.title)
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

/// Empty state for every editing tool: instead of sending people back to
/// the Upscale tab, it opens the photo picker right here.
struct PBNoPhotoState: View {
    let icon: String
    let toolName: String
    var blurb: String?
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @State private var pickerItem: PhotosPickerItem?

    init(icon: String, toolName: String, blurb: String? = nil) {
        self.icon = icon
        self.toolName = toolName
        self.blurb = blurb
    }

    init(tab: AppTab) {
        self.init(icon: tab.systemImage, toolName: tab.title, blurb: tab.blurb + ". Pick a photo to start — edits stack, and Undo covers all of them.")
    }

    var body: some View {
        VStack(spacing: 18) {
            PBEmptyState(icon: icon, title: toolName, message: blurb ?? "Pick a photo to start editing. Every tool works on the same photo, so edits stack — and Undo covers all of them.")
                .frame(maxHeight: 260)
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose Photo", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.pbGradient)
            .padding(.horizontal, 40)
            if viewModel.pasteboardHasImage {
                Button {
                    viewModel.loadFromPasteboard()
                } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.pbGhost)
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: pickerItem) {
            guard let pickerItem else { return }
            await viewModel.load(from: pickerItem)
        }
    }
}

/// Compact capsule tag over photos ("Before", "4032×3024").
struct PBTag: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).pbFont(.monoSmall)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.62), in: Capsule())
    }
}

/// A labeled number tile, e.g. "OUTPUT / 12096×16128".
struct PBMetric: View {
    let label: String
    let value: String
    var tint: Color = PBColor.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .pbFont(.eyebrow)
                .foregroundStyle(PBColor.inkFaint)
            Text(value)
                .pbFont(.mono)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Segmented chips — a lighter, more legible stand-in for a `Menu` when
/// there are only a handful of options.
struct PBSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var icon: ((Value) -> String)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    Haptics.lightImpact()
                    withAnimation(PBMotion.snappy) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        if let icon { Image(systemName: icon(option)).font(.system(size: 11, weight: .bold)) }
                        Text(label(option)).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSelected ? Color.white : PBColor.inkDim)
                    .background(isSelected ? PBColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// A slider with its label and live value on one line.
struct PBValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                Spacer()
                Text(format(value))
                    .pbFont(.monoSmall)
                    .foregroundStyle(PBColor.inkDim)
            }
            Slider(value: $value, in: range)
                .tint(PBColor.accent)
        }
    }
}

/// The app's one primary-action style.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(PBColor.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !PBMotion.isReduced ? 0.98 : 1)
    }
}

/// Secondary action: flat surface, hairline.
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(PBColor.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(configuration.isPressed ? PBColor.surface3 : PBColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PBColor.line, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Square icon button for compact toolbars (Share, Copy, Inspect…).
struct PBIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PBStackedLabelStyle())
            .foregroundStyle(PBColor.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? PBColor.surface3 : PBColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PBColor.line, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Icon over a small title.
struct PBStackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 5) {
            configuration.icon.font(.system(size: 16, weight: .semibold))
            configuration.title.font(.system(size: 10.5, weight: .semibold))
        }
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var pbGradient: GradientButtonStyle { GradientButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var pbGhost: GhostButtonStyle { GhostButtonStyle() }
}

extension ButtonStyle where Self == PBIconButtonStyle {
    static var pbIcon: PBIconButtonStyle { PBIconButtonStyle() }
}

extension View {
    /// Runs `action` when the photo changes — but only while this tab is
    /// on screen. A hidden tab catches up the moment it's shown again, so
    /// edits made elsewhere never trigger work nobody can see.
    func pbRefresh(on version: Int, perform action: @escaping () -> Void) -> some View {
        modifier(PBActiveRefresh(version: version, action: action))
    }
}

private struct PBActiveRefresh: ViewModifier {
    let version: Int
    let action: () -> Void
    @Environment(\.pbIsActiveTab) private var isActive
    @State private var handledVersion: Int?

    func body(content: Content) -> some View {
        content
            .onAppear { if isActive { run() } }
            .onChange(of: isActive) { _, active in if active { run() } }
            .onChange(of: version) { _, _ in if isActive { run() } }
    }

    private func run() {
        guard handledVersion != version else { return }
        handledVersion = version
        action()
    }
}
