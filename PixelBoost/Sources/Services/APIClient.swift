import Foundation

enum APIError: LocalizedError {
    case noServerConfigured
    case badStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .noServerConfigured:
            return "No server configured — set one in Settings first."
        case .badStatus(let code, let detail):
            if let detail { return "Server returned \(code): \(detail)" }
            return "Server returned status \(code)."
        }
    }
}

/// Small shared HTTP client for `upscaler-bridge` — resolves the base URL,
/// attaches the `Authorization` header when configured, and centralizes
/// status-code checking so each `*Service` doesn't reimplement it.
/// `UpscaleHistoryService`/`UpscaleLoggingService`/`CustomPresetService`/
/// `DeviceSettingsService`/`ImportExportService` all build on this.
enum APIClient {
    static func url(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard let baseURL = ServerConfig.baseURL else { throw APIError.noServerConfigured }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw APIError.noServerConfigured }
        return url
    }

    static func request(path: String, method: String = "GET", queryItems: [URLQueryItem] = []) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path, queryItems: queryItems))
        request.httpMethod = method
        if let apiKey = ServerConfig.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Runs `request` and returns its body, throwing `APIError.badStatus`
    /// (with the server's `{"detail": ...}` message, if present) for any
    /// non-2xx response.
    static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    static func upload(_ request: URLRequest, from bodyData: Data) async throws -> Data {
        let (data, response) = try await URLSession.shared.upload(for: request, from: bodyData)
        try checkStatus(response, data: data)
        return data
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
        throw APIError.badStatus(http.statusCode, detail)
    }
}
