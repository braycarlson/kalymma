const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");
const surface_module = @import("../../surface.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Options = surface_module.Options;
const PlatformError = contract.PlatformError;
const RequestError = surface_module.RequestError;
const Surface = surface_module.Surface;

pub fn create(options: *const Options) (CapacityError || PlatformError)!Surface {
    assert(state.is_open());

    const surface = try state.acquire(options);

    if (!state.submit(.create, surface_module.unpack(surface).index)) {
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

    if (state.is_open()) {
        _ = state.submit(.destroy, surface_module.unpack(surface).index);
    }

    state.release(surface);

    assert(state.resolve(surface) == null);
}

pub fn show(surface: Surface) (PlatformError || RequestError)!void {
    assert(state.is_open());

    const slot = state.resolve(surface) orelse return error.SurfaceUnknown;

    if (!state.submit(.show, surface_module.unpack(surface).index)) {
        return error.SurfaceShowFailed;
    }

    slot.visible = true;

    assert(slot.visible);
}

pub fn hide(surface: Surface) void {
    const slot = state.resolve(surface) orelse return;

    slot.visible = false;

    if (state.is_open()) {
        _ = state.submit(.hide, surface_module.unpack(surface).index);
    }

    assert(!slot.visible);
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

    if (!state.submit(.present, surface_module.unpack(surface).index)) {
        return error.SurfacePresentFailed;
    }
}
