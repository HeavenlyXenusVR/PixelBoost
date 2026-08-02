import CoreGraphics
import Foundation
import UIKit

/// Runs a user-pasted Lua script's `apply(r, g, b, a)` function over every
/// pixel of an image — the engine behind the Scripted Filter tool. Backed
/// by the vendored Lua 5.4 interpreter (`Vendor/Lua`, MIT-licensed) via the
/// bridging header, not a Swift package.
///
/// Sandboxing: only the `base` (with `load`/`dofile`/`loadfile` stripped
/// straight back out), `string`, `table`, `math`, and `utf8` libraries are
/// opened — no `io`, `os`, `package`/`require`, or `debug`, and those four
/// libraries' C sources aren't even compiled into the app (see
/// `Vendor/Lua/README.md`). A script has no path to touch the filesystem,
/// spawn a process, load arbitrary bytecode, or introspect the call stack.
/// A count-based instruction hook (`LUA_MASKCOUNT`) also aborts the whole
/// run if a single script is still executing past `timeLimit` — closes the
/// one hole sandboxing the standard libraries can't: a script's own
/// `while true do end`, which would otherwise block whatever thread is
/// running `apply(to:)` forever.
final class LuaFilterEngine {
    enum EngineError: LocalizedError {
        case interpreterUnavailable
        case compileError(String)
        case missingApplyFunction
        case runtimeError(String)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .interpreterUnavailable:
                return "Couldn't start the Lua interpreter."
            case .compileError(let message):
                return "Script error: \(message)"
            case .missingApplyFunction:
                return "The script must define a function named \"apply\" — e.g. function apply(r, g, b, a) return r, g, b, a end"
            case .runtimeError(let message):
                return "Script failed while running: \(message)"
            case .invalidImage:
                return "The image couldn't be read."
            }
        }
    }

    /// Every `apply(to:)` call gets this long before the instruction-count
    /// hook aborts it — generous for a per-pixel function that should be a
    /// handful of arithmetic ops, but enough to stop a genuine infinite
    /// loop from hanging the app indefinitely.
    static let timeLimit: TimeInterval = 5

    /// Full-resolution photos would mean millions of individual Lua calls
    /// (one per pixel) — capped to keep a scripted filter's run time
    /// bounded and predictable, the same reasoning `FiltersView` already
    /// applies to its own preview/thumbnail renders, just larger since this
    /// is the actual applied result, not a preview. Documented in the tool
    /// itself, not just here.
    static let maxAppliedDimension: CGFloat = 900

    private let L: OpaquePointer
    /// Registry reference to the compiled script's `apply` global, so every
    /// pixel call looks it up once (`lua_rawgeti`) instead of a global
    /// table lookup per pixel.
    private var applyRef: Int32 = LUA_NOREF

    /// Instruction-hook deadline. Not per-instance state read by the hook —
    /// the hook is a bare `@convention(c)` function pointer with no
    /// captures, so it reads this off the class itself. `LuaFilterEngine`
    /// is only ever driven synchronously from one call site at a time
    /// (see `PixelArtView`/scripted-filter usage), never two runs
    /// concurrently, so a single shared deadline is safe.
    private static var activeDeadline: Date = .distantFuture

    init() throws {
        guard let state = luaL_newstate() else { throw EngineError.interpreterUnavailable }
        L = state
        openSandboxedLibraries()
    }

    deinit {
        if applyRef != LUA_NOREF {
            luaL_unref(L, LUA_REGISTRYINDEX, applyRef)
        }
        lua_close(L)
    }

    private func openSandboxedLibraries() {
        func require(_ name: String, _ function: lua_CFunction) {
            name.withCString { luaL_requiref(L, $0, function, 1) }
            lua_pop_shim(L, 1)
        }
        require(LUA_GNAME, luaopen_base)
        require(LUA_TABLIBNAME, luaopen_table)
        require(LUA_STRLIBNAME, luaopen_string)
        require(LUA_MATHLIBNAME, luaopen_math)
        require(LUA_UTF8LIBNAME, luaopen_utf8)

        // luaB_dofile/luaB_loadfile (base lib) read straight off the C
        // filesystem via fopen regardless of the io library being absent,
        // and `load` can compile arbitrary precompiled bytecode (a known
        // memory-safety hazard for untrusted input) — all three are
        // removed from the globals a script can see, even though the
        // library that defines them has to stay open for `print`/`pairs`/
        // `pcall`/etc.
        for name in ["load", "dofile", "loadfile"] {
            lua_pushnil(L)
            lua_setglobal(L, name)
        }

        lua_sethook(L, LuaFilterEngine.instructionHook, LUA_MASKCOUNT, 200_000)
    }

    private static let instructionHook: lua_Hook = { state, _ in
        if Date() > LuaFilterEngine.activeDeadline {
            luaL_error(state, "exceeded time limit")
        }
    }

    /// Compiles `script` and resolves its top-level `apply` function.
    /// Throws `.compileError`/`.missingApplyFunction` without touching any
    /// image — call this once up front so a typo shows up immediately
    /// rather than partway through a full-resolution run.
    func compile(_ script: String) throws {
        Self.activeDeadline = Date().addingTimeInterval(Self.timeLimit)
        if luaL_loadstring(L, script) != LUA_OK {
            throw EngineError.compileError(popErrorString())
        }
        if lua_pcall_shim(L, 0, 0, 0) != LUA_OK {
            throw EngineError.compileError(popErrorString())
        }
        lua_getglobal(L, "apply")
        guard lua_isfunction_shim(L, -1) != 0 else {
            lua_pop_shim(L, 1)
            throw EngineError.missingApplyFunction
        }
        if applyRef != LUA_NOREF {
            luaL_unref(L, LUA_REGISTRYINDEX, applyRef)
        }
        applyRef = luaL_ref(L, LUA_REGISTRYINDEX) // pops the function
    }

    /// Runs the compiled `apply(r, g, b, a)` (each 0...1) over every pixel
    /// of `image`, downscaled first to `Self.maxAppliedDimension` if
    /// larger. Returns the transformed image at that (possibly reduced)
    /// size.
    func apply(to image: UIImage) throws -> UIImage {
        guard applyRef != LUA_NOREF else { throw EngineError.missingApplyFunction }
        guard let cgImage = downscaled(image, maxDimension: Self.maxAppliedDimension)?.cgImage else {
            throw EngineError.invalidImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = height * bytesPerRow
        // A genuine heap allocation with a stable address for the whole
        // function, not `&someArray` — CGContext holds onto this pointer
        // and both draws into it and is read from directly (below) well
        // after this initializer call returns, which is outside the
        // narrow "valid for one call" window Swift's array-to-pointer
        // bridging actually guarantees.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        buffer.initialize(repeating: 0, count: byteCount)
        defer { buffer.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EngineError.invalidImage }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        Self.activeDeadline = Date().addingTimeInterval(Self.timeLimit)

        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * bytesPerPixel
            let r = Double(buffer[offset]) / 255.0
            let g = Double(buffer[offset + 1]) / 255.0
            let b = Double(buffer[offset + 2]) / 255.0
            let a = Double(buffer[offset + 3]) / 255.0

            lua_rawgeti(L, LUA_REGISTRYINDEX, lua_Integer(applyRef))
            lua_pushnumber(L, r)
            lua_pushnumber(L, g)
            lua_pushnumber(L, b)
            lua_pushnumber(L, a)
            guard lua_pcall_shim(L, 4, 4, 0) == LUA_OK else {
                let message = popErrorString()
                throw EngineError.runtimeError(message)
            }

            // `return r, g, b, a` leaves the stack with `a` on top (last
            // pushed) and `r` at the bottom (first pushed) — pop in that
            // reverse order to land each value back in its matching byte.
            buffer[offset + 3] = componentByte(popNumber(defaultingTo: a))
            buffer[offset + 2] = componentByte(popNumber(defaultingTo: b))
            buffer[offset + 1] = componentByte(popNumber(defaultingTo: g))
            buffer[offset] = componentByte(popNumber(defaultingTo: r))
        }

        guard let outputCGImage = context.makeImage() else { throw EngineError.invalidImage }
        return UIImage(cgImage: outputCGImage, scale: 1, orientation: .up)
    }

    /// Pops the top Lua stack value as a Double, clamped to 0...1 — used
    /// for each of the 4 return values `apply` leaves on the stack. Falls
    /// back to `defaultValue` (the corresponding input channel) if the
    /// script returned something non-numeric, rather than failing the
    /// whole pixel over one bad return value.
    private func popNumber(defaultingTo defaultValue: Double) -> Double {
        defer { lua_pop_shim(L, 1) }
        guard lua_isnumber(L, -1) != 0 else { return defaultValue }
        return min(1, max(0, lua_tonumberx(L, -1, nil)))
    }

    private func componentByte(_ value: Double) -> UInt8 {
        UInt8((value * 255).rounded())
    }

    private func popErrorString() -> String {
        defer { lua_pop_shim(L, 1) }
        guard let cString = lua_tolstring(L, -1, nil) else { return "unknown error" }
        return String(cString: cString)
    }

    private func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
