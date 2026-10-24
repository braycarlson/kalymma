const std = @import("std");

const contract = @import("../contract.zig");
const runtime = @import("runtime.zig");
const state = @import("state.zig");
const surface_module = @import("../../surface.zig");
const window = @import("window.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Options = surface_module.Options;
const PlatformError = contract.PlatformError;
const RequestError = surface_module.RequestError;
const Surface = surface_module.Surface;

pub fn create(options: *const Options) (CapacityError || PlatformError)!Surface {
    assert(state.is_open());

    const surface = try state.acquire(options);

    if (!runtime.dispatch(window.message_create, surface_module.unpack(surface).index)) {
        state.release(surface);

        return error.SurfaceCreateFailed;
    }

    assert(state.resolve(surface) != null);

    return surface;
}

pub fn destroy(surface: Surface) void {
    if (state.resolve(surface) == null) {
        return;
    }

    _ = runtime.dispatch(window.message_destroy, surface_module.unpack(surface).index);

    state.release(surface);

    assert(state.resolve(surface) == null);
}

pub fn show(surface: Surface) (PlatformError || RequestError)!void {
    assert(state.is_open());

    if (state.resolve(surface) == null) {
        return error.SurfaceUnknown;
    }

    if (!runtime.dispatch(window.message_show, surface_module.unpack(surface).index)) {
        return error.SurfaceShowFailed;
    }
}

pub fn hide(surface: Surface) void {
    if (state.resolve(surface) == null) {
        return;
    }

    _ = runtime.dispatch(window.message_hide, surface_module.unpack(surface).index);
}

pub fn is_visible(surface: Surface) bool {
    const slot = state.resolve(surface) orelse return false;
    return slot.visible;
}

pub fn frame(surface: Surface) []u32 {
    return state.frame_of(surface);
}

pub fn present(surface: Surface) (PlatformError || RequestError)!void {
    assert(state.is_open());

    const slot = state.resolve(surface) orelse return error.SurfaceUnknown;

    if (!slot.visible) {
        return;
    }

    if (!runtime.dispatch(window.message_present, surface_module.unpack(surface).index)) {
        return error.SurfacePresentFailed;
    }
}
