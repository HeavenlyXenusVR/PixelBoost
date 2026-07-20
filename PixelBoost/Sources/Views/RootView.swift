import SwiftUI

/// App root: every tab's content stays mounted the whole time (toggled
/// with opacity/hit-testing, never removed from the tree) so switching
/// tabs never loses in-progress state — crop selection, paint strokes,
/// slider positions, whatever a tab was in the middle of. That's the
/// tradeoff for a custom scrollable bar instead of a native `TabView`
/// (which would do this for free, but only for ~5 tabs before collapsing
/// the rest into "More" — not workable for a dozen tabs).
struct RootView: View {
    @EnvironmentObject private var provider: UpscalerProvider
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var showingToolsDrawer = false

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                tabContent(tab)
                    .opacity(selectedTab == tab ? 1 : 0)
                    .allowsHitTesting(selectedTab == tab)
                    .zIndex(selectedTab == tab ? 1 : 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Applied once, at launch, before any tab switching — a
            // shared photo waiting in the App Group container (checked
            // right after) always wins and jumps to Home regardless, same
            // as it already did before this setting existed.
            selectedTab = provider.defaultTab
            consumeSharedPhotoIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { consumeSharedPhotoIfNeeded() }
        }
        .sheet(isPresented: $showingToolsDrawer) {
            ToolsDrawerView(selectedTab: selectedTab) { tab in
                Haptics.lightImpact()
                selectedTab = tab
                showingToolsDrawer = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    /// The Share Extension runs in a separate process and can only drop a
    /// photo into a shared App Group container (see `SharedPhotoBridge`) —
    /// this is the main app's side of that hand-off, checked on launch and
    /// every time the app comes back to the foreground (covers both "share
    /// into PixelBoost while it's not running" and "share while it's
    /// already open in the background").
    private func consumeSharedPhotoIfNeeded() {
        guard let image = SharedPhotoBridge.consumePendingImage() else { return }
        viewModel.loadSharedImage(image)
        selectedTab = .home
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: ContentView()
        case .cutout: CutoutTabView()
        case .enhance: AutoEnhanceView()
        case .adjust: AdjustmentsView()
        case .selective: SelectiveAdjustView()
        case .crop: CropRotateView()
        case .filters: FiltersView()
        case .overlays: OverlaysView()
        case .erase: InpaintView()
        case .restore: RestoreView()
        case .clone: CloneStampView()
        case .batch: NavigationStack { BatchUpscaleView(provider: provider) }
        case .cloud: NavigationStack { CloudView() }
        case .history: NavigationStack { HistoryView() }
        case .settings: NavigationStack { SettingsView() }
        }
    }

    /// 5 fixed primary tabs plus a center "Tools" launcher for the other
    /// 10 (`AppTab.moreTabs`, via `showingToolsDrawer`'s sheet) — replaces
    /// the old horizontally-scrolling 15-icon strip, which crammed every
    /// destination into one undifferentiated row.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.primaryTabs.prefix(2)) { tab in
                tabButton(tab).frame(maxWidth: .infinity)
            }
            toolsButton.frame(maxWidth: .infinity)
            ForEach(AppTab.primaryTabs.dropFirst(2)) { tab in
                tabButton(tab).frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 64)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(PBColor.line).frame(height: 1)
        }
    }

    private func tabButton(_ tab: AppTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            Haptics.lightImpact()
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                Capsule()
                    .fill(isSelected ? PBColor.accent : .clear)
                    .frame(width: 14, height: 3)
            }
            .foregroundStyle(isSelected ? PBColor.accent : PBColor.inkDim)
            .padding(.vertical, 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    /// Distinct raised-circle treatment so the launcher for the other 10
    /// tabs reads as its own thing, not a 6th identical icon — and lights
    /// up in accent when the currently active tab lives behind it, so
    /// there's still a sense of "where am I" even though that tab isn't
    /// individually represented in the bar.
    private var toolsButton: some View {
        let isMoreTabActive = !selectedTab.isPrimary
        return Button {
            Haptics.lightImpact()
            showingToolsDrawer = true
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(isMoreTabActive ? AnyShapeStyle(PBColor.accentGradient) : AnyShapeStyle(PBColor.surface2))
                        .frame(width: 42, height: 42)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: isMoreTabActive ? PBColor.accent.opacity(0.5) : .clear, radius: 10, x: 0, y: 4)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isMoreTabActive ? .white : PBColor.inkDim)
                }
                .offset(y: -8)
                Text(isMoreTabActive ? selectedTab.title : "Tools")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isMoreTabActive ? PBColor.accent : PBColor.inkDim)
                    .lineLimit(1)
                    .offset(y: -4)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The "Tools" drawer sheet — a grid of every non-primary tab
/// (`AppTab.moreTabs`), tap to select and dismiss.
private struct ToolsDrawerView: View {
    let selectedTab: AppTab
    let onSelect: (AppTab) -> Void

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AppTab.moreTabs) { tab in
                        let isSelected = tab == selectedTab
                        Button { onSelect(tab) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(isSelected ? PBColor.accent : PBColor.ink)
                                    .frame(width: 56, height: 56)
                                    .pbGlassSurface(cornerRadius: 18)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(isSelected ? PBColor.accent : .clear, lineWidth: 1.5)
                                    )
                                Text(tab.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(PBColor.inkDim)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

#Preview {
    let provider = UpscalerProvider()
    RootView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
