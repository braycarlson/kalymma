const std = @import("std");

const contract = @import("../contract.zig");
const runtime = @import("runtime.zig");
const state = @import("state.zig");
const window = @import("window.zig");

const assert = std.debug.assert;

const Handle = contract.Handle;
const SurfaceConfig = contract.SurfaceConfig;

pub const Error = contract.SurfaceError;

pub fn create(config: *const SurfaceConfig) Error!Handle {
    if (!state.is_open()) {
        return Error.NotOpen;
    }

    const handle = try state.acquire(config);

    if (!runtime.dispatch(window.message_create, handle.index)) {
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

    _ = runtime.dispatch(window.message_destroy, handle.index);

    state.release(handle);

    assert(state.resolve(handle) == null);
}

pub fn show(handle: Handle) Error!void {
    if (!state.is_open()) {
        return Error.NotOpen;
    }

    if (state.resolve(handle) == null) {
        return Error.NotFound;
    }

    if (!runtime.dispatch(window.message_show, handle.index)) {
        return Error.Failed;
    }
}

pub fn hide(handle: Handle) void {
    if (state.resolve(handle) == null) {
        return;
    }

    _ = runtime.dispatch(window.message_hide, handle.index);
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

    if (!runtime.dispatch(window.message_present, handle.index)) {
        return Error.Failed;
    }
}

pub fn scale(handle: Handle) u32 {
    const slot = state.resolve(handle) orelse return 1;

    assert(slot.scale >= 1);
    assert(slot.scale <= contract.scale_max);

    return slot.scale;
}
