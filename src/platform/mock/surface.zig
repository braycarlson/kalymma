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

    state.record(.create);

    if (state.should_fail(.create)) {
        return error.SurfaceCreateFailed;
    }

    const surface = try state.acquire(options);

    assert(state.resolve(surface) != null);

    return surface;
}

pub fn destroy(surface: Surface) void {
    state.record(.destroy);
    state.release(surface);

    assert(state.resolve(surface) == null);
}

pub fn show(surface: Surface) (PlatformError || RequestError)!void {
    state.record(.show);

    if (state.should_fail(.show)) {
        return error.SurfaceShowFailed;
    }

    const slot = state.resolve(surface) orelse return error.SurfaceUnknown;

    slot.visible = true;

    assert(slot.visible);
}

pub fn hide(surface: Surface) void {
    state.record(.hide);

    const slot = state.resolve(surface) orelse return;

    slot.visible = false;

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
    state.record(.present);

    if (state.should_fail(.present)) {
        return error.SurfacePresentFailed;
    }

    if (state.resolve(surface) == null) {
        return error.SurfaceUnknown;
    }
}
