//
// Thin Objective-C interface over tinyexr (Vendor/TinyEXR, C++) — Swift can
// only bridge to C/Objective-C directly, so the actual decode+tonemap logic
// lives in EXRDecoder.mm (Objective-C++) and this header is what
// PixelBoost-Bridging-Header.h actually exposes to Swift.
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EXRDecoder : NSObject

/// Decodes an OpenEXR file's RGB(A) beauty pass and tonemaps it to a plain
/// display-referred `UIImage`, the same 0-255 convention every other image
/// source in the app already produces. Returns `nil` and sets `outError` on
/// any failure (missing file, unsupported EXR feature, decode error) —
/// never partial/garbage output.
+ (nullable UIImage *)decodeEXRAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END
