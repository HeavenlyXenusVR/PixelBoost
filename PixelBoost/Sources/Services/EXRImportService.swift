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
    /// - Parameter tonemap: which HDR->display-referred curve to use —
    ///   see `EXRTonemap`/`EXRDecoder.mm`'s doc comment. Defaults to the
    ///   user's Settings choice (`EXRTonemapPreference`).
    static func loadImage(from url: URL, tonemap: EXRTonemap = EXRTonemapPreference.current) throws -> UIImage {
        var errorMessage: NSString?
        guard let image = EXRDecoder.decodeEXR(atPath: url.path, tonemap: tonemap, error: &errorMessage) else {
            throw ImportError.decodeFailed((errorMessage as String?) ?? "Unknown error")
        }
        return image
    }

    /// A companion depth (Z) pass, as a grayscale mask — see
    /// `EXRDecoder.decodeEXRDepth(atPath:error:)`'s doc comment. Used by
    /// `DepthFogService`.
    static func loadDepthImage(from url: URL) throws -> UIImage {
        var errorMessage: NSString?
        guard let image = EXRDecoder.decodeEXRDepth(atPath: url.path, error: &errorMessage) else {
            throw ImportError.decodeFailed((errorMessage as String?) ?? "Unknown error")
        }
        return image
    }

    /// A companion Ambient Occlusion (or other already-0...1) pass — see
    /// `EXRDecoder.decodeEXRMask(atPath:error:)`'s doc comment. Used by
    /// `AOBlendService`.
    static func loadMaskImage(from url: URL) throws -> UIImage {
        var errorMessage: NSString?
        guard let image = EXRDecoder.decodeEXRMask(atPath: url.path, error: &errorMessage) else {
            throw ImportError.decodeFailed((errorMessage as String?) ?? "Unknown error")
        }
        return image
    }
}

/// Settings-backed default tonemap for EXR import — a plain `AppStorage`-
/// compatible key rather than a `@Published` service, so both SwiftUI
/// Settings controls and this non-View call site can read/write the same
/// value without threading a view model through.
enum EXRTonemapPreference {
    static let defaultsKey = "com.pixelboost.exrTonemap"

    static var current: EXRTonemap {
        EXRTonemap(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .reinhard
    }
}

extension EXRTonemap {
    // Swift already imports the NS_ENUM cases as `.reinhard`/`.filmic`
    // (common-prefix stripping from `EXRTonemapReinhard`/`EXRTonemapFilmic`)
    // — no need to redeclare them here, just add the display-name mapping.
    var displayName: String {
        switch self {
        case .reinhard: return "Reinhard"
        case .filmic: return "Filmic"
        @unknown default: return "Reinhard"
        }
    }
}
