const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");
const win32 = @import("win32.zig");
const window = @import("window.zig");

const assert = std.debug.assert;

const RuntimeConfig = contract.RuntimeConfig;

pub const Error = contract.RuntimeError;

pub fn open(config: RuntimeConfig) Error!void {
    if (!config.is_valid()) {
        return Error.Failed;
    }

    if (state.current() != .idle) {
        return Error.AlreadyOpen;
    }

    state.set_status(.starting);

    const spawned = std.Thread.spawn(.{}, pump, .{}) catch {
        state.set_status(.idle);

        return Error.Failed;
    };

    state.set_thread(spawned);

    contract.wait_ready(state) catch |err| {
        stop();

        return err;
    };

    assert(state.is_open());
}

pub fn close() void {
    if (state.get_thread() == null) {
        return;
    }

    stop();

    state.clear_events();
    state.clear_surfaces();

    assert(!state.is_open());
}

pub fn is_open() bool {
    return state.is_open();
}

fn stop() void {
    const present = state.get_thread() orelse {
        state.set_status(.idle);

        return;
    };

    if (state.get_controller()) |handle| {
        _ = win32.PostMessageW(handle, window.message_stop, 0, 0);
    }

    present.join();

    state.set_thread(null);
    state.set_status(.idle);

    assert(state.get_thread() == null);
}

fn pump() void {
    if (!window.register_classes()) {
        state.set_status(.failed);

        return;
    }
    defer window.unregister_classes();

    const controller = window.create_controller() orelse {
        state.set_status(.failed);

        return;
    };

    state.set_controller(controller);
    defer {
        state.set_controller(null);

        _ = win32.DestroyWindow(controller);
    }

    state.set_status(.running);

    var message = win32.MSG{};

    while (win32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&message);
        _ = win32.DispatchMessageW(&message);
    }
}

pub fn dispatch(code: u32, index: u16) bool {
    assert(index < state.surfaces_max);

    const controller = state.get_controller() orelse return false;

    const result = win32.SendMessageW(controller, code, index, 0);

    return result == window.result_ok;
}
