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
#include <limits>
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

// Narkowicz's fitted approximation of the ACES filmic tonemap curve — a
// widely-used, cheap (no LUT, no per-channel matrix) stand-in for the real
// ACES RRT+ODT pipeline. Rolls off highlights more gradually than Reinhard
// and lands closer to what Blender's Filmic/AgX view transforms produce on
// the same scene, at the cost of being a fixed curve fit rather than the
// genuine color-managed pipeline.
float filmicTonemap(float x) {
    x = std::max(0.0f, x);
    const float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
    return std::max(0.0f, std::min(1.0f, (x * (a * x + b)) / (x * (c * x + d) + e)));
}

float applyTonemap(float x, EXRTonemap tonemap) {
    switch (tonemap) {
        case EXRTonemapFilmic: return filmicTonemap(x);
        case EXRTonemapReinhard: default: return reinhardTonemap(x);
    }
}

// Shared by both decode entry points: runs LoadEXR, and hands back the raw
// float buffer + dimensions on success. Caller owns `outRGBA` (tinyexr
// malloc's it — `free()` when done) and must check the return value before
// touching `outRGBA`/`outWidth`/`outHeight`.
bool loadRawEXR(NSString *path, float **outRGBA, int *outWidth, int *outHeight, NSString * _Nullable * _Nullable outError) {
    const char *tinyexrError = nullptr;
    int ret = LoadEXR(outRGBA, outWidth, outHeight, path.UTF8String, &tinyexrError);
    if (ret != TINYEXR_SUCCESS) {
        if (outError) {
            *outError = tinyexrError ? [NSString stringWithUTF8String:tinyexrError] : @"Unknown EXR decode error";
        }
        if (tinyexrError) { FreeEXRErrorMessage(tinyexrError); }
        return false;
    }
    if (*outWidth <= 0 || *outHeight <= 0 || *outRGBA == nullptr) {
        if (outError) { *outError = @"EXR file decoded with invalid dimensions"; }
        return false;
    }
    return true;
}

UIImage *_Nullable makeImage(const std::vector<uint8_t> &pixels, int width, int height, NSString * _Nullable * _Nullable outError) {
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

}  // namespace

@implementation EXRDecoder

+ (nullable UIImage *)decodeEXRAtPath:(NSString *)path tonemap:(EXRTonemap)tonemap error:(NSString * _Nullable * _Nullable)outError {
    float *rawRGBA = nullptr;
    int width = 0;
    int height = 0;
    if (!loadRawEXR(path, &rawRGBA, &width, &height, outError)) { return nil; }

    size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    std::vector<uint8_t> pixels(pixelCount * 4);
    for (size_t i = 0; i < pixelCount; i++) {
        const float *src = &rawRGBA[i * 4];
        uint8_t *dst = &pixels[i * 4];
        dst[0] = static_cast<uint8_t>(std::lround(srgbEncode(applyTonemap(src[0], tonemap)) * 255.0f));
        dst[1] = static_cast<uint8_t>(std::lround(srgbEncode(applyTonemap(src[1], tonemap)) * 255.0f));
        dst[2] = static_cast<uint8_t>(std::lround(srgbEncode(applyTonemap(src[2], tonemap)) * 255.0f));
        // Alpha is already a display-referred coverage value in [0,1] for a
        // typical render's alpha channel, not scene-linear radiance — no
        // tonemap, just clamp+scale.
        dst[3] = static_cast<uint8_t>(std::lround(std::max(0.0f, std::min(1.0f, src[3])) * 255.0f));
    }
    free(rawRGBA);

    return makeImage(pixels, width, height, outError);
}

+ (nullable UIImage *)decodeEXRDepthAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)outError {
    float *rawRGBA = nullptr;
    int width = 0;
    int height = 0;
    if (!loadRawEXR(path, &rawRGBA, &width, &height, outError)) { return nil; }

    size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    // A depth/Z pass has no fixed range the way color does (world-space
    // units, arbitrary scene scale, often including a very large/"infinity"
    // background value) — min-max normalize per-image rather than assuming
    // any particular range, then invert so near=bright/far=dark, matching
    // how depth masks are conventionally read (a plain grayscale preview
    // reads as "brighter = closer" the same way a Z-depth AOV thumbnail
    // does in every compositor).
    float minZ = std::numeric_limits<float>::max();
    float maxZ = std::numeric_limits<float>::lowest();
    for (size_t i = 0; i < pixelCount; i++) {
        float z = rawRGBA[i * 4];  // R channel — a depth pass is single-channel, replicated across RGB by LoadEXR
        if (std::isfinite(z)) {
            minZ = std::min(minZ, z);
            maxZ = std::max(maxZ, z);
        }
    }
    float range = std::max(1e-6f, maxZ - minZ);

    std::vector<uint8_t> pixels(pixelCount * 4);
    for (size_t i = 0; i < pixelCount; i++) {
        float z = rawRGBA[i * 4];
        float normalized = std::isfinite(z) ? std::max(0.0f, std::min(1.0f, (z - minZ) / range)) : 1.0f;  // treat inf/background as "far"
        uint8_t value = static_cast<uint8_t>(std::lround((1.0f - normalized) * 255.0f));
        uint8_t *dst = &pixels[i * 4];
        dst[0] = dst[1] = dst[2] = value;
        dst[3] = 255;
    }
    free(rawRGBA);

    return makeImage(pixels, width, height, outError);
}

@end
