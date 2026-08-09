const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const Handle = contract.Handle;
const SurfaceConfig = contract.SurfaceConfig;

pub const Error = contract.SurfaceError;

pub fn create(config: *const SurfaceConfig) Error!Handle {
    state.record(.create);

    if (state.should_fail(.create)) {
        return Error.Failed;
    }

    if (!state.is_open()) {
        return Error.NotOpen;
    }

    const handle = try state.acquire(config);

    assert(handle.is_valid());

    return handle;
}

pub fn destroy(handle: Handle) void {
    state.record(.destroy);
    state.release(handle);

    assert(state.resolve(handle) == null);
}

pub fn show(handle: Handle) Error!void {
    state.record(.show);

    if (state.should_fail(.show)) {
        return Error.Failed;
    }

    const slot = state.resolve(handle) orelse {
        return Error.NotFound;
    };

    slot.visible = true;

    assert(slot.visible);
}

pub fn hide(handle: Handle) void {
    state.record(.hide);

    const slot = state.resolve(handle) orelse return;

    slot.visible = false;

    assert(!slot.visible);
}

pub fn is_visible(handle: Handle) bool {
    const slot = state.resolve(handle) orelse return false;

    return slot.visible;
}

pub fn frame(handle: Handle) []u32 {
    return state.frame_of(handle);
}

pub fn present(handle: Handle) Error!void {
    state.record(.present);

    if (state.should_fail(.present)) {
        return Error.Failed;
    }

    if (state.resolve(handle) == null) {
        return Error.NotFound;
    }
}

pub fn scale(handle: Handle) u32 {
    const slot = state.resolve(handle) orelse return 1;

    assert(slot.scale >= 1);
    assert(slot.scale <= contract.scale_max);

    return slot.scale;
}
