import UIKit

/// One row of metadata from `GET /import` or `GET /export` — never
/// includes the image bytes themselves (see `ImportExportService.download`
/// for that).
struct StoredImageEntry: Decodable, Identifiable {
    let id: String
    let device_id: String
    let created_at: String
    let expires_at: String
    let filename: String?
    let content_type: String
    let width: Int
    let height: Int
    let file_size_bytes: Int
}

struct StoredImageUploadResult: Decodable {
    let id: String
    let expires_in_hours: Int
    let width: Int
    let height: Int
}

private struct StoredImageListResponse: Decodable {
    let entries: [StoredImageEntry]
}

/// Uploads/downloads images to `upscaler-bridge`'s temporary (auto-
/// expiring) storage — `image_imports` (pre-upscale) or `image_exports`
/// (post-upscale). Opt-in scratch storage, not a sync mechanism: the
/// on-device upscale flow itself never touches this.
enum ImportExportService {
    /// Matches the server's singular route names (`/import`, `/export`).
    enum Kind: String {
        case imports = "import"
        case exports = "export"
    }

    @discardableResult
    static func upload(
        _ image: UIImage, kind: Kind, historyID: String? = nil, ttlHours: Int? = nil
    ) async throws -> StoredImageUploadResult {
        guard let pngData = image.pngData() else { throw UpscaleError.invalidImage }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("device_id", DeviceIdentity.current)
        if kind == .exports, let historyID {
            appendField("history_id", historyID)
        }
        if let ttlHours {
            appendField("ttl_hours", String(ttlHours))
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(pngData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = try APIClient.request(path: kind.rawValue, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try await APIClient.upload(request, from: body)
        return try JSONDecoder().decode(StoredImageUploadResult.self, from: data)
    }

    static func list(kind: Kind) async throws -> [StoredImageEntry] {
        let request = try APIClient.request(path: kind.rawValue, queryItems: [
            URLQueryItem(name: "device_id", value: DeviceIdentity.current),
        ])
        let data = try await APIClient.data(for: request)
        return try JSONDecoder().decode(StoredImageListResponse.self, from: data).entries
    }

    static func download(id: String, kind: Kind) async throws -> UIImage {
        let request = try APIClient.request(path: "\(kind.rawValue)/\(id)")
        let data = try await APIClient.data(for: request)
        guard let image = UIImage(data: data) else { throw UpscaleError.invalidImage }
        return image
    }

    static func delete(id: String, kind: Kind) async throws {
        let request = try APIClient.request(path: "\(kind.rawValue)/\(id)", method: "DELETE")
        _ = try await APIClient.data(for: request)
    }
}
