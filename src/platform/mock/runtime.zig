const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const PlatformError = contract.PlatformError;

pub fn open() PlatformError!void {
    assert(!state.is_open());

    state.record(.open);

    if (state.should_fail(.open)) {
        return error.DisplayUnavailable;
    }

    state.mark_open();

    assert(state.is_open());
}

pub fn close() void {
    state.record(.close);
    state.set_subscriber(null, null);
    state.surfaces().clear();
    state.mark_closed();

    assert(!state.is_open());
    assert(state.surfaces().count() == 0);
}

pub fn is_open() bool {
    return state.is_open();
}
