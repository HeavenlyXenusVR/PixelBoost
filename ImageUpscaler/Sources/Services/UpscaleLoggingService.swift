import Foundation

/// Posts `UpscaleLogEntry` records to a deployed `upscaler-bridge` (see
/// server/README.md). Fire-and-forget by design: a logging failure must
/// never surface to the user or block the upscale flow it's describing, so
/// every failure path here just prints to the console instead of throwing.
enum UpscaleLoggingService {
    static func log(_ entry: UpscaleLogEntry) {
        guard let baseURL = ServerConfig.baseURL else { return }
        Task.detached(priority: .background) {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("log/upscale"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(entry)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    print("UpscaleLoggingService: server returned status \(http.statusCode)")
                }
            } catch {
                print("UpscaleLoggingService: failed to log upscale — \(error.localizedDescription)")
            }
        }
    }
}
