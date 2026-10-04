import PhotosUI
import SwiftUI

/// App root.
///
/// **State is preserved, work isn't wasted.** A tab is only built the
/// first time it's visited, then stays mounted (hidden with opacity) so
/// switching away and back never loses a crop selection, paint strokes or
/// slider positions. Previously all 24 screens were built at launch and
/// every one of them re-processed the photo whenever it changed — about
/// twenty full-image downscales on the main thread per edit, for screens
/// nobody was looking at. Now hidden tabs also learn they're hidden
/// (`pbIsActiveTab`) and defer their refresh until they're shown again.
struct RootView: View {
    @EnvironmentObject private var provider: UpscalerProvider
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var visitedTabs: Set<AppTab> = [.home]
    /// The last tool used, so the dock's Tools button returns to it.
    @State private var lastTool: AppTab?

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                if visitedTabs.contains(tab) {
                    tabContent(tab)
                        .environment(\.pbIsActiveTab, selectedTab == tab)
                        .environment(\.pbShowTools, { select(.tools) })
                        .opacity(selectedTab == tab ? 1 : 0)
                        .allowsHitTesting(selectedTab == tab)
                        .accessibilityHidden(selectedTab != tab)
                        .zIndex(selectedTab == tab ? 1 : 0)
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Stays put behind the keyboard instead of riding up over it.
            dock.ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .onChange(of: selectedTab) { previous, tab in
            ActionLoggingService.log("tab_change", detail: [
                "from": previous.rawValue, "to": tab.rawValue,
            ])
        }
        .preferredColorScheme(.dark)
        .onAppear {
            select(provider.defaultTab)
            consumeSharedPhotoIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { consumeSharedPhotoIfNeeded() }
        }
    }

    private func select(_ tab: AppTab) {
        visitedTabs.insert(tab)
        if tab.isTool { lastTool = tab }
        selectedTab = tab
    }

    /// The Share Extension drops a photo into the App Group container (see
    /// `SharedPhotoBridge`); pick it up on launch and on every foreground.
    private func consumeSharedPhotoIfNeeded() {
        guard let image = SharedPhotoBridge.consumePendingImage() else { return }
        viewModel.loadSharedImage(image)
        select(.home)
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: ContentView()
        case .tools: ToolsLibraryView(lastTool: lastTool) { select($0) }
        case .cutout: CutoutTabView()
        case .enhance: AutoEnhanceView()
        case .adjust: AdjustmentsView()
        case .selective: SelectiveAdjustView()
        case .crop: CropRotateView()
        case .frames: FramesView()
        case .filters: FiltersView()
        case .pixelArt: PixelArtView()
        case .scripted: ScriptedFilterView()
        case .overlays: OverlaysView()
        case .erase: InpaintView()
        case .restore: RestoreView()
        case .renderDenoise: RenderDenoiseView()
        case .normalMap: NormalMapToolView()
        case .seamlessTexture: SeamlessTextureView()
        case .depthFog: DepthFogView()
        case .aoBlend: AOBlendView()
        case .lut: LUTToolView()
        case .clone: CloneStampView()
        case .batch: NavigationStack { BatchUpscaleView(provider: provider) }
        case .cloud: NavigationStack { CloudView() }
        case .history: NavigationStack { HistoryView() }
        case .settings: NavigationStack { SettingsView() }
        }
    }

    // MARK: - Dock

    /// A floating, solid (not blurred) capsule. The Tools slot doubles as
    /// "where am I": while a tool is open it shows that tool's icon.
    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.primaryTabs) { tab in
                dockButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(PBColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(PBColor.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .overlay(alignment: .top) {
            if viewModel.isUpscaling || viewModel.isComparing, selectedTab != .home {
                runningPill
                    .offset(y: -34)
            }
        }
    }

    private func dockButton(_ tab: AppTab) -> some View {
        let isSelected = selectedTab == tab || (tab == .tools && selectedTab.isTool)
        let icon = tab == .tools && selectedTab.isTool ? selectedTab.systemImage : tab.systemImage
        let title = tab == .tools && selectedTab.isTool ? selectedTab.title : tab.title
        return Button {
            Haptics.lightImpact()
            if tab == .tools, selectedTab == .tools, let lastTool {
                select(lastTool)
            } else {
                select(tab)
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? PBColor.ink : PBColor.inkFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? PBColor.surface3 : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Visible from any other screen while an upscale runs: progress at a
    /// glance and one tap back to the live view.
    private var runningPill: some View {
        Button {
            select(.home)
        } label: {
            HStack(spacing: 8) {
                ProgressView(value: viewModel.isComparing ? viewModel.comparisonProgress : viewModel.progress)
                    .progressViewStyle(.circular)
                    .tint(PBColor.accent)
                    .scaleEffect(0.7)
                Text(viewModel.isPaused ? "Paused" : "Upscaling \(Int((viewModel.isComparing ? viewModel.comparisonProgress : viewModel.progress) * 100))%")
                    .pbFont(.monoSmall)
                    .foregroundStyle(PBColor.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(PBColor.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(PBColor.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The Tools library: the current photo at the top, then every editing
/// tool as a described tile, grouped by what it's for, with search.
private struct ToolsLibraryView: View {
    let lastTool: AppTab?
    let onSelect: (AppTab) -> Void
    @EnvironmentObject private var viewModel: UpscalerViewModel
    @State private var query = ""
    @State private var pickerItem: PhotosPickerItem?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    photoHeader
                    if query.isEmpty, let lastTool {
                        VStack(alignment: .leading, spacing: 8) {
                            PBSectionLabel(title: "Continue")
                            toolTile(lastTool, wide: true)
                        }
                    }
                    ForEach(AppTab.Category.allCases) { category in
                        let tabs = category.tabs.filter(matches)
                        if !tabs.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                PBSectionLabel(title: category.rawValue)
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(tabs) { toolTile($0, wide: false) }
                                }
                            }
                        }
                    }
                }
                .padding(PBLayout.gutter)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find a tool")
            .pbScreen("Tools", tool: false)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PBUndoRedoButtons()
                }
            }
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                await viewModel.load(from: pickerItem)
            }
        }
    }

    private func matches(_ tab: AppTab) -> Bool {
        query.isEmpty
            || tab.title.localizedCaseInsensitiveContains(query)
            || tab.blurb.localizedCaseInsensitiveContains(query)
    }

    /// What every tool will work on, so it's never a surprise.
    @ViewBuilder
    private var photoHeader: some View {
        HStack(spacing: 14) {
            Group {
                if let image = viewModel.displayResult ?? viewModel.displaySource {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PBColor.inkFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PBColor.surface2)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PBColor.line, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                if let cg = (viewModel.resultImage ?? viewModel.sourceImage)?.cgImage {
                    Text(viewModel.resultImage == nil ? "Original photo" : "Edited photo")
                        .pbFont(.headline)
                        .foregroundStyle(PBColor.ink)
                    Text("\(cg.width)×\(cg.height) · \(String(format: "%.1f", Double(cg.width * cg.height) / 1_000_000)) MP")
                        .pbFont(.monoSmall)
                        .foregroundStyle(PBColor.inkDim)
                } else {
                    Text("No photo yet")
                        .pbFont(.headline)
                        .foregroundStyle(PBColor.ink)
                    Text("Tools edit one shared photo.")
                        .pbFont(.caption)
                        .foregroundStyle(PBColor.inkDim)
                }
            }
            Spacer()
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                    .frame(width: 40, height: 40)
                    .background(PBColor.surface2, in: Circle())
            }
            .accessibilityLabel("Choose Photo")
        }
        .padding(12)
        .pbGlassSurface(cornerRadius: 20)
    }

    private func toolTile(_ tab: AppTab, wide: Bool) -> some View {
        Button {
            Haptics.lightImpact()
            onSelect(tab)
        } label: {
            HStack(alignment: wide ? .center : .top, spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PBColor.accent)
                    .frame(width: 34, height: 34)
                    .background(PBColor.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PBColor.ink)
                        .lineLimit(1)
                    Text(tab.blurb)
                        .pbFont(.caption)
                        .foregroundStyle(PBColor.inkDim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if wide {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PBColor.inkFaint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: wide ? 0 : 92, alignment: .topLeading)
            .pbGlassSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let provider = UpscalerProvider()
    RootView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
