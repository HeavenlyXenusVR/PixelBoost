import Foundation
import UIKit

/// Swift-side entry point for EXR import — thin wrapper over the
/// Objective-C `EXRDecoder` (see EXRDecoder.h/.mm, bridged via
/// PixelBoost-Bridging-Header.h), which does the actual tinyexr decode +
/// HDR tonemap. Exists as its own file/enum (rather than calling
/// `EXRDecoder` directly from the view) purely so every other service in
/// this app follows the same "Service does the work, View just calls it"
/// shape — `EXRDecoder` itself already carries the real documentation.
enum EXRImportService {
    enum ImportError: LocalizedError {
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .decodeFailed(let message):
                return "Couldn't read that EXR file: \(message)"
            }
        }
    }

    /// - Parameter url: a security-scoped URL from `.fileImporter` — the
    ///   caller is responsible for `startAccessingSecurityScopedResource()`/
    ///   `stopAccessingSecurityScopedResource()` around this call.
    static func loadImage(from url: URL) throws -> UIImage {
        var errorMessage: NSString?
        guard let image = EXRDecoder.decodeEXR(atPath: url.path, error: &errorMessage) else {
            throw ImportError.decodeFailed((errorMessage as String?) ?? "Unknown error")
        }
        return image
    }
}
