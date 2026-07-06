import SwiftUI

@main
struct PixelBoostApp: App {
    // Owned once at the app level (not inside ContentView) so Settings'
    // model/quality pickers and ContentView's upscale flow share the same
    // UpscalerProvider — a picker change is visible to whichever screen
    // runs the next upscale, with no separate sync mechanism needed.
    @StateObject private var provider: UpscalerProvider
    @StateObject private var viewModel: UpscalerViewModel

    init() {
        let provider = UpscalerProvider()
        _provider = StateObject(wrappedValue: provider)
        _viewModel = StateObject(wrappedValue: UpscalerViewModel(provider: provider))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(provider)
                .environmentObject(viewModel)
        }
    }
}
