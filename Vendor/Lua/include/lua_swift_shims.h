//
// A handful of the Lua C API's most-used entry points (lua_pop, lua_pcall,
// lua_isfunction, ...) are function-like macros in lua.h, not real
// functions — fine for C callers, but Swift's Clang importer only bridges
// actual functions (including `static inline` ones), never macros with
// parameters. These thin wrappers exist purely so `LuaFilterEngine.swift`
// has something callable; each one does exactly what the macro it wraps
// does, nothing more.
//
#ifndef lua_swift_shims_h
#define lua_swift_shims_h

#include "lauxlib.h"
#include "lua.h"

static inline void lua_pop_shim(lua_State *L, int n) {
    lua_pop(L, n);
}

static inline int lua_pcall_shim(lua_State *L, int nargs, int nresults, int msgh) {
    return lua_pcall(L, nargs, nresults, msgh);
}

static inline int lua_isfunction_shim(lua_State *L, int idx) {
    return lua_isfunction(L, idx);
}

// `LUA_REGISTRYINDEX` is itself defined in terms of other macros
// (`-LUAI_MAXSTACK - 1000`) rather than a single literal, which Swift's
// Clang importer doesn't reliably fold into an importable constant — a
// real `static const int` (evaluated once, at C compile time) always
// bridges cleanly.
static const int LUA_REGISTRYINDEX_SHIM = LUA_REGISTRYINDEX;

// `luaL_error`/`lua_pushfstring` are variadic C functions — Swift refuses
// to call *any* variadic C function directly ("Variadic function is
// unavailable"), even with zero extra arguments. This wraps the one thing
// `LuaFilterEngine`'s instruction-count hook needs: push a fixed message
// and raise it as a Lua error (`lua_error` itself is a plain, non-variadic
// function that throws whatever's on top of the stack).
static inline int lua_error_shim(lua_State *L, const char *message) {
    lua_pushstring(L, message);
    return lua_error(L);
}

#endif /* lua_swift_shims_h */
