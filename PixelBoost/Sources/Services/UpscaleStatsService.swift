import Foundation

/// Aggregate stats for this device's full history — see server/main.py's
/// `get_stats` for why this is a real server-side aggregation rather than
/// something computed client-side over the capped `/log/history` fetch.
struct UpscaleStats: Decodable {
    let total: Int
    let successes: Int
    let failures: Int
    let success_rate: Double?
    let avg_processing_ms: Double?
    let total_output_pixels: Int
}

enum UpscaleStatsService {
    static func fetchOwn() async throws -> UpscaleStats {
        let request = try APIClient.request(path: "log/stats", queryItems: [
            URLQueryItem(name: "device_id", value: DeviceIdentity.current),
        ])
        let data = try await APIClient.data(for: request)
        return try JSONDecoder().decode(UpscaleStats.self, from: data)
    }
}
