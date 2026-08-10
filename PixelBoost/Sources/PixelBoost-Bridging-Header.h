//
// Exposes the vendored Lua 5.4 C API (see Vendor/Lua/README.md) to Swift —
// only `LuaFilterEngine.swift` actually calls into these — plus
// `EXRDecoder`, the Objective-C wrapper around vendored TinyEXR (see
// Vendor/TinyEXR/README.md) that `EXRImportService.swift` calls into.
//
#ifndef PixelBoost_Bridging_Header_h
#define PixelBoost_Bridging_Header_h

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lua_swift_shims.h"

#import "EXRDecoder.h"

#endif /* PixelBoost_Bridging_Header_h */
