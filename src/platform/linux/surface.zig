const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const Handle = contract.Handle;
const SurfaceConfig = contract.SurfaceConfig;

pub const Error = contract.SurfaceError;

pub fn create(config: *const SurfaceConfig) Error!Handle {
    if (!state.is_open()) {
        return Error.NotOpen;
    }

    const handle = try state.acquire(config);

    if (!state.submit(.create, handle.index)) {
        state.release(handle);

        return Error.Failed;
    }

    assert(handle.is_valid());

    return handle;
}

pub fn destroy(handle: Handle) void {
    if (state.resolve(handle) == null) {
        return;
    }

    if (state.is_open()) {
        _ = state.submit(.destroy, handle.index);
    }

    state.release(handle);

    assert(state.resolve(handle) == null);
}

pub fn show(handle: Handle) Error!void {
    if (!state.is_open()) {
        return Error.NotOpen;
    }

    const slot = state.resolve(handle) orelse {
        return Error.NotFound;
    };

    if (!state.submit(.show, handle.index)) {
        return Error.Failed;
    }

    slot.visible = true;

    assert(slot.visible);
}

pub fn hide(handle: Handle) void {
    const slot = state.resolve(handle) orelse return;

    slot.visible = false;

    if (state.is_open()) {
        _ = state.submit(.hide, handle.index);
    }

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
    if (!state.is_open()) {
        return Error.NotOpen;
    }

    const slot = state.resolve(handle) orelse {
        return Error.NotFound;
    };

    if (!slot.visible) {
        return;
    }

    if (!state.submit(.present, handle.index)) {
        return Error.Failed;
    }
}

pub fn scale(handle: Handle) u32 {
    const slot = state.resolve(handle) orelse return 1;

    assert(slot.scale >= 1);
    assert(slot.scale <= contract.scale_max);

    return slot.scale;
}
