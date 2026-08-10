import AppIntents
import UIKit
import UniformTypeIdentifiers

/// Runs a real upscale in-process (no need to open the app first) via a
/// photo handed in from Shortcuts, Siri, Spotlight, or the share sheet —
/// same `CoreMLTileUpscaler`/`UpscaleRunner` pipeline every other upscale
/// path in the app uses, just driven from outside the UI. Falls back to
/// `LanczosUpscaler` the same way the in-app picker does if the General
/// Photo model somehow isn't bundled — never a silent no-op.
struct UpscalePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Upscale Photo"
    static let description = IntentDescription("Upscales a photo using PixelBoost's on-device General Photo model.")

    @Parameter(title: "Photo")
    var photo: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let sourceImage = UIImage(data: photo.data) else {
            throw UpscaleError.invalidImage
        }

        let upscaler: ImageUpscaling
        if let coreML = try? CoreMLTileUpscaler(modelName: UpscaleModelChoice.generalPhoto.modelName) {
            upscaler = coreML
        } else {
            upscaler = LanczosUpscaler()
        }

        let outcome = await UpscaleRunner.run(sourceImage, using: upscaler, sourceFileSizeBytes: photo.data.count) { _ in }
        guard let result = outcome.result, let pngData = result.image.pngData() else {
            throw outcome.error ?? UpscaleError.noModelOutput
        }

        let resultFile = IntentFile(data: pngData, filename: "upscaled.png", type: .png)
        return .result(value: resultFile)
    }
}

/// Simpler counterpart for when there's no photo to pass in directly (Siri
/// "open PixelBoost and upscale a photo" rather than a Shortcuts pipeline
/// step) — just brings the app to the front on its default tab, same as
/// tapping the app icon. `openAppWhenRun` is what actually does the
/// foregrounding; there's deliberately no in-process work here since
/// picking a photo needs the real `PhotosPicker` UI.
struct OpenUpscalerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PixelBoost to Upscale"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Registers both intents with the system so they're discoverable from
/// Siri, Spotlight, and the Shortcuts app without the user having to know
/// they exist first — the whole point of App Intents over a
/// Shortcuts-only integration. Phrases use `applicationName` so they read
/// naturally regardless of what the App Store listing ends up calling the
/// app.
struct PixelBoostShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UpscalePhotoIntent(),
            phrases: [
                "Upscale a photo with \(.applicationName)",
                "Upscale this photo in \(.applicationName)",
            ],
            shortTitle: "Upscale Photo",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: OpenUpscalerIntent(),
            phrases: [
                "Open \(.applicationName) to upscale",
            ],
            shortTitle: "Open to Upscale",
            systemImageName: "photo.on.rectangle"
        )
    }
}
