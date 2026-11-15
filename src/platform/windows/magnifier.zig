const std = @import("std");

const tint_module = @import("../../tint.zig");
const win32 = @import("win32.zig");

const assert = std.debug.assert;

const Initialize = *const fn () callconv(.winapi) win32.BOOL;
const Magnifier = @This();
const SetEffect = *const fn (effect: *const Effect) callconv(.winapi) win32.BOOL;
const Uninitialize = *const fn () callconv(.winapi) win32.BOOL;

initialized: bool = false,
module: ?win32.HMODULE = null,

const Effect = extern struct {
    transform: tint_module.Transform,
};

const Library = struct {
    initialize: Initialize,
    set_effect: SetEffect,
    uninitialize: Uninitialize,
};

const library_name = std.unicode.utf8ToUtf16LeStringLiteral("Magnification.dll");

comptime {
    assert(@sizeOf(Effect) == 100);
    assert(library_name.len > 0);
}

pub fn apply(magnifier: *Magnifier, color: u32) bool {
    const library = magnifier.load() orelse return false;

    if (!magnifier.initialized) {
        if (library.initialize() == win32.FALSE) {
            return false;
        }

        magnifier.initialized = true;
    }

    const effect = Effect{ .transform = tint_module.transform(color) };

    if (library.set_effect(&effect) == win32.FALSE) {
        magnifier.clear();

        return false;
    }

    assert(magnifier.initialized);
    assert(magnifier.module != null);

    return true;
}

pub fn clear(magnifier: *Magnifier) void {
    if (!magnifier.initialized) {
        return;
    }

    magnifier.initialized = false;

    const library = magnifier.load() orelse return;
    const identity = Effect{ .transform = tint_module.transform(0) };

    _ = library.set_effect(&identity);
    _ = library.uninitialize();

    assert(!magnifier.initialized);
    assert(magnifier.module != null);
}

pub fn is_available(magnifier: *Magnifier) bool {
    const result = magnifier.load() != null;

    if (result) assert(magnifier.module != null);
    if (!result) assert(magnifier.module == null);

    return result;
}

pub fn release(magnifier: *Magnifier) void {
    magnifier.clear();

    if (magnifier.module) |module| {
        _ = win32.FreeLibrary(module);
        magnifier.module = null;
    }

    assert(!magnifier.initialized);
    assert(magnifier.module == null);
}

fn load(magnifier: *Magnifier) ?Library {
    if (magnifier.initialized) assert(magnifier.module != null);

    if (magnifier.module == null) {
        magnifier.module = win32.LoadLibraryExW(
            library_name,
            null,
            win32.LOAD_LIBRARY_SEARCH_SYSTEM32,
        );
    }

    const module = magnifier.module orelse return null;

    const library = resolve(module) orelse {
        assert(!magnifier.initialized);

        _ = win32.FreeLibrary(module);
        magnifier.module = null;

        return null;
    };

    assert(magnifier.module != null);

    return library;
}

fn resolve(module: win32.HMODULE) ?Library {
    const initialize = win32.GetProcAddress(module, "MagInitialize") orelse return null;
    const effect = win32.GetProcAddress(module, "MagSetFullscreenColorEffect") orelse return null;
    const uninitialize = win32.GetProcAddress(module, "MagUninitialize") orelse return null;

    const result = Library{
        .initialize = @ptrCast(initialize),
        .set_effect = @ptrCast(effect),
        .uninitialize = @ptrCast(uninitialize),
    };

    return result;
}
