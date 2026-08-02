//
// Exposes the vendored Lua 5.4 C API (see Vendor/Lua/README.md) to Swift.
// Only `LuaFilterEngine.swift` actually calls into these; every other
// Swift file in the app is unaffected by this header's contents.
//
#ifndef PixelBoost_Bridging_Header_h
#define PixelBoost_Bridging_Header_h

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lua_swift_shims.h"

#endif /* PixelBoost_Bridging_Header_h */
