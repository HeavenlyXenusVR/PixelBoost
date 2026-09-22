import SwiftUI
import UIKit

@main
struct PixelBoostApp: App {
    // Owned once at the app level (not inside ContentView) so Settings'
    // model/quality pickers and ContentView's upscale flow share the same
    // UpscalerProvider — a picker change is visible to whichever screen
    // runs the next upscale, with no separate sync mechanism needed.
    @StateObject private var provider: UpscalerProvider
    @StateObject private var viewModel: UpscalerViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let provider = UpscalerProvider()
        _provider = StateObject(wrappedValue: provider)
        _viewModel = StateObject(wrappedValue: UpscalerViewModel(provider: provider))

        // Battery level/state read as "unknown" unless monitoring is
        // explicitly enabled — without this every telemetry snapshot would
        // record a nil battery level forever.
        UIDevice.current.isBatteryMonitoringEnabled = true
        TelemetryService.record("session_start", detail: [
            "model_choice": provider.modelChoice.rawValue,
            "quality": provider.quality.rawValue,
            "detail": provider.detail.rawValue,
            "scale": provider.scaleFactor.rawValue,
            "temporary_cloud_save": provider.temporaryCloudSaveEnabled,
        ])
        TelemetryService.snapshot(reason: "launch")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(provider)
                .environmentObject(viewModel)
                // Deliberate single-theme commitment (see Views/Theme.swift)
                // — the redesign is built for a dark canvas throughout, the
                // same choice Halide/Darkroom/Lightroom make by default,
                // not a partial dark-mode adaptation of a light design.
                .preferredColorScheme(.dark)
                .task { await TelemetryMonitor.shared.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                TelemetryService.snapshot(reason: "foreground")
            case .background:
                TelemetryService.record("session_background", detail: [
                    "uptime_s": Int(Date().timeIntervalSince(TelemetryService.launchedAt)),
                ])
                TelemetryService.snapshot(reason: "background")
                // Backgrounding is the last reliable moment to send: the
                // process can be suspended (or killed outright) before any
                // buffered flush timer would have fired.
                TelemetryService.flush()
            default:
                break
            }
        }
    }
}

/// Ambient telemetry that isn't tied to any user action: a periodic
/// snapshot while the app is in use, plus the two system notifications
/// worth a row of their own — thermal state changes (the context behind
/// every "why did this upscale get throttled" question) and memory
/// warnings (the last thing seen before an OOM kill, which by definition
/// can't log anything itself).
@MainActor
final class TelemetryMonitor {
    static let shared = TelemetryMonitor()
    private var started = false

    /// Long enough that a background trickle of snapshots is cheap, short
    /// enough to catch a device heating up over the course of one big batch.
    private let snapshotInterval: TimeInterval = 300

    private init() {}

    func start() async {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            TelemetryService.record("thermal_state_change", detail: [
                "state": TelemetryService.thermalStateName,
            ])
            TelemetryService.snapshot(reason: "thermal_change")
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            TelemetryService.record("memory_warning", detail: [
                "used_mb": TelemetryService.usedMemoryMB,
            ])
            // Sent immediately rather than buffered: if this warning is the
            // prelude to a jetsam kill, a flush 30 seconds from now never
            // happens.
            TelemetryService.snapshot(reason: "memory_warning")
            TelemetryService.flush()
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(snapshotInterval))
            guard !Task.isCancelled else { return }
            TelemetryService.snapshot(reason: "periodic")
        }
    }
}
