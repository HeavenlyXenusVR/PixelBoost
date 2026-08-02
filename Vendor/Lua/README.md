# Vendored Lua 5.4.7

Unmodified upstream Lua 5.4.7 (https://www.lua.org/ftp/lua-5.4.7.tar.gz),
MIT-licensed (see `LICENSE`), vendored directly as C sources rather than a
Swift Package — this project has no other external dependencies and
XcodeGen's `sources:` list already handles mixed C/Swift in one target via
a bridging header, so a full SPM package wrapper would just be extra
indirection for a single small library.

`src/` and `include/` are the upstream `lua-5.4.7/src` directory, split by
extension, with these files **removed**:

- `lua.c`, `luac.c` — the standalone `lua`/`luac` command-line executables
  (each defines its own `main()`, which would collide with the app's own).
- `liolib.c`, `loslib.c`, `loadlib.c`, `ldblib.c` — the `io`, `os`,
  `package`/`require`, and `debug` standard libraries. `LuaFilterEngine`
  (`PixelBoost/Sources/Services/LuaFilterEngine.swift`) only opens `base`
  (with `load`/`dofile`/`loadfile` immediately stripped back out),
  `string`, `table`, `math`, and `utf8` — a user-pasted script has no path
  to touch the filesystem, spawn a process, load arbitrary bytecode, or
  introspect the call stack. Leaving these four files out of the build
  entirely (rather than just not calling `luaopen_*` on them) means there's
  no C function sitting in the binary that a future change could
  accidentally re-expose.

No source lines were otherwise edited — diffing `src/*.c`/`include/*.h`
against a fresh upstream tarball (minus the six removed files) should show
no differences.
