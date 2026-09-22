import Foundation
import UIKit

/// One app run's worth of telemetry plumbing: a session id every event is
/// tagged with, the ambient device context (thermal/battery/memory/disk)
/// that no single event can supply on its own, and a buffer so "telemetry
/// on everything" doesn't mean one HTTP request per tap.
///
/// Sits underneath `ActionLoggingService` (which keeps its existing
/// `log(_:detail:)` shape for the couple dozen call sites that already use
/// it) rather than replacing it. `UpscaleRunner` reads `context` directly
/// for the richer per-run columns on `upscale_history`.
///
/// Everything here is best-effort and silent: telemetry must never surface
/// an error to the user or block the action it describes. It's also
/// user-disableable — see `diagnosticsEnabled` — and posts nothing at all
/// when no server is configured.
enum TelemetryService {
    /// Regenerated per app launch. Groups a run's events together without
    /// needing an account or any new persistent identifier beyond the
    /// install-scoped `DeviceIdentity`.
    static let sessionID = UUID().uuidString
    static let launchedAt = Date()

    static let diagnosticsEnabledDefaultsKey = "com.pixelboost.diagnosticsEnabled"

    /// Defaults to on (this is the always-on debug logging the README
    /// describes), but a single switch in Settings turns off every event,
    /// snapshot and upscale log this file feeds.
    static var isEnabled: Bool {
        guard ServerConfig.baseURL != nil else { return false }
        return UserDefaults.standard.object(forKey: diagnosticsEnabledDefaultsKey) as? Bool ?? true
    }

    // MARK: - Device context

    struct Context {
        let thermalState: String
        let lowPowerMode: Bool
        let batteryLevel: Double?
        let batteryState: String
        let physicalMemoryMB: Int
        let usedMemoryMB: Int?
        let freeDiskMB: Int?
    }

    static var context: Context {
        Context(
            thermalState: thermalStateName,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: batteryLevel,
            batteryState: batteryStateName,
            physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            usedMemoryMB: usedMemoryMB,
            freeDiskMB: freeDiskMB
        )
    }

    static var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static var batteryLevel: Double? {
        // -1 means "monitoring not enabled / unknown" rather than an actual
        // level; `PixelBoostApp` turns monitoring on at launch.
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    private static var batteryStateName: String {
        switch UIDevice.current.batteryState {
        case .charging: return "charging"
        case .full: return "full"
        case .unplugged: return "unplugged"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    /// This task's resident footprint, via `task_info` — public API (the
    /// same numbers Xcode's memory gauge reads), not a private SPI. `nil`
    /// rather than a bogus 0 if the call fails, so a failure reads as
    /// "unknown" server-side instead of "used no memory".
    static var usedMemoryMB: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    private static var freeDiskMB: Int? {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(available / 1_048_576)
    }

    // MARK: - Event buffer

    /// Serializes buffer access — events are logged from the main actor,
    /// background tool work, and detached logging tasks alike.
    private static let queue = DispatchQueue(label: "com.pixelboost.telemetry")
    private static var buffer: [ActionLogEntry] = []
    private static var flushScheduled = false
    /// Flush when the buffer reaches this many events, rather than waiting
    /// out the timer — keeps a burst (a batch run, a fast sequence of tool
    /// taps) from sitting unsent.
    private static let flushThreshold = 20
    private static let flushInterval: TimeInterval = 30
    /// A hard ceiling so a long offline session can't grow this without
    /// bound; oldest events are dropped first.
    private static let maxBuffered = 500

    static func record(
        _ action: String,
        detail: [String: Any?] = [:],
        outcome: String? = nil,
        durationMS: Int? = nil
    ) {
        guard isEnabled else { return }
        let entry = ActionLogEntry(
            device_id: DeviceIdentity.current,
            action: action,
            detail: encodeDetail(detail),
            app_version: Self.appVersion,
            os_version: UIDevice.current.systemVersion,
            device_model: UIDevice.current.model,
            session_id: sessionID,
            outcome: outcome,
            duration_ms: durationMS,
            thermal_state: thermalStateName
        )
        queue.async {
            buffer.append(entry)
            if buffer.count > maxBuffered {
                buffer.removeFirst(buffer.count - maxBuffered)
            }
            if buffer.count >= flushThreshold {
                flushLocked()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + flushInterval) {
                    flushScheduled = false
                    flushLocked()
                }
            }
        }
    }

    /// Settings changes arrive in bursts — a slider drag fires its
    /// property observer on every intermediate value — so the last value
    /// per setting wins after a short quiet period instead of recording the
    /// whole drag. Keyed by setting name, so two different settings changed
    /// in quick succession both still land.
    private static var pendingSettings: [String: Any] = [:]

    static func recordSettingChange(_ setting: String, value: Any) {
        guard isEnabled else { return }
        queue.async {
            let isFirst = pendingSettings[setting] == nil
            pendingSettings[setting] = value
            guard isFirst else { return }
            queue.asyncAfter(deadline: .now() + 1.5) {
                guard let settled = pendingSettings.removeValue(forKey: setting) else { return }
                record("settings_change", detail: ["setting": setting, "value": settled])
            }
        }
    }

    /// Sends anything buffered now — called on the timer, at the size
    /// threshold, and when the app backgrounds (where "later" may never
    /// come).
    static func flush() {
        queue.async { flushLocked() }
    }

    private static func flushLocked() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        Task.detached(priority: .background) {
            do {
                var request = try APIClient.request(path: "log/actions", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(ActionLogBatch(entries: batch))
                _ = try await APIClient.data(for: request)
            } catch {
                // Dropped, not retried: this is a debug log, and a retry
                // queue that outlives the process would be a bigger
                // mechanism than the data is worth.
                print("TelemetryService: dropped \(batch.count) events — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Ambient snapshots

    /// Posts one `device_snapshots` row. Called at launch, on
    /// foreground/background, when the thermal state changes, and on a
    /// timer while the app is in use.
    static func snapshot(reason: String) {
        guard isEnabled else { return }
        let context = Self.context
        let uptime = Int(Date().timeIntervalSince(launchedAt))
        Task.detached(priority: .background) {
            let payload = DeviceSnapshotPayload(
                device_id: DeviceIdentity.current,
                session_id: sessionID,
                reason: reason,
                thermal_state: context.thermalState,
                low_power_mode: context.lowPowerMode,
                battery_level: context.batteryLevel,
                battery_state: context.batteryState,
                physical_memory_mb: context.physicalMemoryMB,
                used_memory_mb: context.usedMemoryMB,
                free_disk_mb: context.freeDiskMB,
                session_uptime_s: uptime,
                app_version: Self.appVersion,
                os_version: await UIDevice.current.systemVersion,
                device_model: await UIDevice.current.model
            )
            do {
                var request = try APIClient.request(path: "log/snapshot", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(payload)
                _ = try await APIClient.data(for: request)
            } catch {
                print("TelemetryService: snapshot failed — \(error.localizedDescription)")
            }
        }
    }

    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func encodeDetail(_ detail: [String: Any?]) -> String? {
        guard !detail.isEmpty else { return nil }
        // NSNull for nil values — JSONSerialization drops entries whose
        // value is Swift's `nil` outright rather than encoding `null`, and
        // "this key was absent" vs "this key was explicitly nil" is a real
        // distinction worth keeping in a debug log.
        let normalized = detail.mapValues { $0 ?? NSNull() }
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Mirrors the server's `ActionLogBatch` (see server/main.py).
struct ActionLogBatch: Encodable {
    let entries: [ActionLogEntry]
}

/// Mirrors the server's `DeviceSnapshot` (see server/main.py).
struct DeviceSnapshotPayload: Encodable {
    let device_id: String
    let session_id: String?
    let reason: String?
    let thermal_state: String?
    let low_power_mode: Bool?
    let battery_level: Double?
    let battery_state: String?
    let physical_memory_mb: Int?
    let used_memory_mb: Int?
    let free_disk_mb: Int?
    let session_uptime_s: Int?
    let app_version: String?
    let os_version: String?
    let device_model: String?
}
