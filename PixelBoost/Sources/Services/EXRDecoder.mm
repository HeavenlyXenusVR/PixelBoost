//
// Objective-C++ implementation backing EXRDecoder.h — the actual tinyexr
// (Vendor/TinyEXR, C++) call plus the HDR->display-referred tonemap.
//
// EXR stores scene-linear HDR radiance (unbounded — a bright highlight can
// be far above 1.0), but every other image source in this app (PhotosPicker,
// the upscale/edit pipeline, PhotoLibrarySaver) assumes display-referred
// 0-255 sRGB, same as a plain PNG/JPEG. Converting between the two needs a
// tonemap, not just a clamp — clamping a bright highlight straight to 255
// crushes it to a flat white blob, while a tonemap compresses the highlight
// down into range while preserving relative brightness. Uses a plain
// Reinhard tonemap (`x / (x + 1)`, the same one Blender's own view transform
// options include) — deliberately simple/fixed rather than user-adjustable,
// same "no device here to tune a second axis against real output" reasoning
// as PhotoAdjustments' vignette radius — followed by a standard sRGB
// transfer-function encode (not a flat gamma-2.2 approximation) so midtones
// land close to how the same scene would look tonemapped in Blender's
// Filmic/Standard view transform.
//
#import "EXRDecoder.h"

#define TINYEXR_IMPLEMENTATION
#define TINYEXR_USE_MINIZ 0
#include <zlib.h>
#include "tinyexr.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

float srgbEncode(float linear) {
    linear = std::max(0.0f, std::min(1.0f, linear));
    if (linear <= 0.0031308f) {
        return linear * 12.92f;
    }
    return 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
}

float reinhardTonemap(float x) {
    x = std::max(0.0f, x);  // EXR can carry negative values from some renderers' compositing; treat as black
    return x / (x + 1.0f);
}

}  // namespace

@implementation EXRDecoder

+ (nullable UIImage *)decodeEXRAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)outError {
    float *rawRGBA = nullptr;
    int width = 0;
    int height = 0;
    const char *tinyexrError = nullptr;

    int ret = LoadEXR(&rawRGBA, &width, &height, path.UTF8String, &tinyexrError);
    if (ret != TINYEXR_SUCCESS) {
        if (outError) {
            *outError = tinyexrError
                ? [NSString stringWithUTF8String:tinyexrError]
                : @"Unknown EXR decode error";
        }
        if (tinyexrError) {
            FreeEXRErrorMessage(tinyexrError);
        }
        return nil;
    }
    if (width <= 0 || height <= 0 || rawRGBA == nullptr) {
        if (outError) { *outError = @"EXR file decoded with invalid dimensions"; }
        return nil;
    }

    size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    std::vector<uint8_t> pixels(pixelCount * 4);
    for (size_t i = 0; i < pixelCount; i++) {
        const float *src = &rawRGBA[i * 4];
        uint8_t *dst = &pixels[i * 4];
        dst[0] = static_cast<uint8_t>(std::lround(srgbEncode(reinhardTonemap(src[0])) * 255.0f));
        dst[1] = static_cast<uint8_t>(std::lround(srgbEncode(reinhardTonemap(src[1])) * 255.0f));
        dst[2] = static_cast<uint8_t>(std::lround(srgbEncode(reinhardTonemap(src[2])) * 255.0f));
        // Alpha is already a display-referred coverage value in [0,1] for a
        // typical render's alpha channel, not scene-linear radiance — no
        // tonemap, just clamp+scale.
        dst[3] = static_cast<uint8_t>(std::lround(std::max(0.0f, std::min(1.0f, src[3])) * 255.0f));
    }
    free(rawRGBA);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, pixels.data(), pixels.size());
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGImageRef cgImage = CGImageCreate(
        static_cast<size_t>(width), static_cast<size_t>(height),
        8, 32, static_cast<size_t>(width) * 4,
        colorSpace,
        kCGImageAlphaLast | kCGBitmapByteOrderDefault,
        provider, nullptr, false, kCGRenderingIntentDefault
    );
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(colorSpace);

    if (!cgImage) {
        if (outError) { *outError = @"Failed to build an image from decoded EXR pixel data"; }
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

@end
