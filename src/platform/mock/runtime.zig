const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const RuntimeConfig = contract.RuntimeConfig;

pub const Error = contract.RuntimeError;

pub fn open(config: RuntimeConfig) Error!void {
    state.record(.open);

    if (state.should_fail(.open)) {
        return Error.Unavailable;
    }

    if (state.is_open()) {
        return Error.AlreadyOpen;
    }

    if (!config.is_valid()) {
        return Error.Failed;
    }

    state.set_name(config.name);
    state.set_open(true);

    assert(state.is_open());
}

pub fn close() void {
    state.record(.close);
    state.set_subscriber(null, null);
    state.surfaces().clear();
    state.set_open(false);

    assert(!state.is_open());
    assert(state.surfaces().count() == 0);
}

pub fn is_open() bool {
    return state.is_open();
}
