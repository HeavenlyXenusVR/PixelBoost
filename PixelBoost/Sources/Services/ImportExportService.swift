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
        // Was unconditionally `image.pngData()` — lossless PNG of a
        // 4x-upscaled photo (easily 50MP+) routinely blew past the
        // server's upload size cap for perfectly ordinary opaque photos
        // that never needed lossless encoding in the first place. Reuses
        // PhotoLibrarySaver's same "PNG only if there's real alpha to
        // preserve, JPEG otherwise" heuristic — a fixed 0.85 quality here
        // rather than the user's Photos-save quality setting, since this
        // debug/cloud-backup path is a separate concern from the local
        // save format Settings actually control.
        guard let (encodedImageData, isPNG) = Self.encode(image) else { throw UpscaleError.invalidImage }

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

        let filename = isPNG ? "image.png" : "image.jpg"
        let contentType = isPNG ? "image/png" : "image/jpeg"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(encodedImageData)
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

    /// Huge photos can still exceed the server's 60MB multipart cap when the
    /// upscale finishes and the auto-backup path immediately tries to encode the
    /// full result, even after the in-memory tiling fix. Downsample only the
    /// upload/export copy, never the actual result image the user sees, so the
    /// app doesn't OOM right when it hits 100% just because cloud backup was
    /// trying to emit a full-resolution PNG/JPEG of a 20MP+ source.
    private static func boundedForUpload(_ image: UIImage) -> UIImage {
        let pixelBudget: Double = 16_000_000
        let pixels = Double(image.size.width) * Double(image.size.height)
        guard pixels > pixelBudget, pixels > 0 else { return image }

        let scale = sqrt(pixelBudget / pixels)
        let targetSize = CGSize(
            width: max(1, image.size.width * CGFloat(scale)),
            height: max(1, image.size.height * CGFloat(scale))
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !image.hasAlphaChannel
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// - Returns: the encoded bytes and whether they're PNG (vs. JPEG) —
    ///   the caller needs to know which to set the right filename/
    ///   Content-Type on the multipart upload.
    private static func encode(_ image: UIImage) -> (data: Data, isPNG: Bool)? {
        let uploadImage = boundedForUpload(image)
        guard let data = PhotoLibrarySaver.encodedData(for: uploadImage, format: .auto, quality: 0.85) else { return nil }
        return (data, uploadImage.hasAlphaChannel)
    }
}
