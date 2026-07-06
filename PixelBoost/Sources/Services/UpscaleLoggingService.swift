import Foundation

/// Posts `UpscaleLogEntry` records to a deployed `upscaler-bridge` (see
/// server/README.md). Fire-and-forget by design: a logging failure must
/// never surface to the user or block the upscale flow it's describing, so
/// every failure path here just prints to the console instead of throwing.
enum UpscaleLoggingService {
    static func log(_ entry: UpscaleLogEntry) {
        guard ServerConfig.baseURL != nil else { return }
        Task.detached(priority: .background) {
            do {
                var request = try APIClient.request(path: "log/upscale", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(entry)
                _ = try await APIClient.data(for: request)
            } catch {
                print("UpscaleLoggingService: failed to log upscale — \(error.localizedDescription)")
            }
        }
    }
}
