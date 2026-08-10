//
// Thin Objective-C interface over tinyexr (Vendor/TinyEXR, C++) — Swift can
// only bridge to C/Objective-C directly, so the actual decode+tonemap logic
// lives in EXRDecoder.mm (Objective-C++) and this header is what
// PixelBoost-Bridging-Header.h actually exposes to Swift.
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Which HDR->display-referred tonemap curve to apply — see EXRDecoder.mm's
/// doc comment. `EXRTonemapReinhard` (`x / (x + 1)`) is a neutral, cheap
/// default; `EXRTonemapFilmic` (the Narkowicz ACES approximation) rolls off
/// highlights more gently and lands closer to what Blender's Filmic/AgX
/// view transforms produce, at the cost of being a fixed curve fit rather
/// than the "true" ACES pipeline.
typedef NS_ENUM(NSInteger, EXRTonemap) {
    EXRTonemapReinhard = 0,
    EXRTonemapFilmic = 1,
};

@interface EXRDecoder : NSObject

/// Decodes an OpenEXR file's RGB(A) beauty pass and tonemaps it to a plain
/// display-referred `UIImage`, the same 0-255 convention every other image
/// source in the app already produces. Returns `nil` and sets `outError` on
/// any failure (missing file, unsupported EXR feature, decode error) —
/// never partial/garbage output.
+ (nullable UIImage *)decodeEXRAtPath:(NSString *)path tonemap:(EXRTonemap)tonemap error:(NSString * _Nullable * _Nullable)outError;

/// Loads a single-channel (depth/Z) EXR pass as a grayscale `UIImage` —
/// min-max normalized per-image (world-space Z values have no fixed range
/// the way color does), *not* tonemapped like the beauty pass above. Used
/// by `DepthFogService` for depth-based fog/blur compositing.
+ (nullable UIImage *)decodeEXRDepthAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END
