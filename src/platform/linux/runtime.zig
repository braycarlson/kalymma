const std = @import("std");

const contract = @import("../contract.zig");
const display = @import("display.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const RuntimeConfig = contract.RuntimeConfig;

pub const Error = contract.RuntimeError;

pub const poll_in: i16 = 1;
pub const poll_timeout_ms: i32 = 200;

comptime {
    assert(poll_in == 1);
    assert(poll_timeout_ms > 0);
}

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
        join();

        return err;
    };

    assert(state.is_open());
}

pub fn close() void {
    if (state.get_thread() == null) {
        return;
    }

    if (state.is_open()) {
        _ = state.submit(.stop, 0);
    }

    join();

    state.clear_events();
    state.clear_surfaces();

    assert(!state.is_open());
}

pub fn is_open() bool {
    return state.is_open();
}

fn join() void {
    const present = state.get_thread() orelse {
        state.set_status(.idle);

        return;
    };

    present.join();

    state.set_thread(null);
    state.set_status(.idle);

    assert(state.get_thread() == null);
}

fn pump() void {
    display.open() catch {
        state.set_status(.failed);

        return;
    };

    defer display.close();

    const wake = sys.event_fd() catch {
        state.set_status(.failed);

        return;
    };

    state.set_wake(wake);
    defer {
        state.set_wake(-1);

        sys.close(wake);
    }

    state.set_status(.running);

    loop(wake);

    state.abandon();
}

fn loop(wake: sys.Fd) void {
    var running = true;

    while (running) {
        var fds = [_]std.os.linux.pollfd{
            .{ .fd = display.descriptor(), .events = poll_in, .revents = 0 },
            .{ .fd = wake, .events = poll_in, .revents = 0 },
        };

        const ready = sys.wait(&fds, poll_timeout_ms) catch {
            break;
        };

        if (ready > 0 and fds[0].revents != 0) {
            display.pump();
        }

        if (ready > 0 and fds[1].revents != 0) {
            sys.consume(wake);
        }

        running = serve();

        if (!display.is_live()) {
            break;
        }
    }
}

fn serve() bool {
    const request = state.take() orelse return true;

    if (request.kind == .stop) {
        state.complete(true);

        return false;
    }

    const succeeded = perform(request.kind, request.index);

    state.complete(succeeded);

    return true;
}

fn perform(kind: state.Request, index: u16) bool {
    assert(index < state.surfaces_max);

    const slot = state.slot_at(index);

    switch (kind) {
        .create => {
            display.create(index, slot) catch {
                return false;
            };
        },
        .destroy => {
            display.destroy(index);
        },
        .show => {
            display.show(index, slot) catch {
                return false;
            };

            return publish_frame(index, slot);
        },
        .hide => {
            display.hide(index);
        },
        .present => {
            return publish_frame(index, slot);
        },
        else => {
            return false;
        },
    }

    return true;
}

fn publish_frame(index: u16, slot: *const contract.Slot) bool {
    if (!display.is_mapped(index)) {
        return true;
    }

    const pixels = state.frame_at(index);

    display.present(index, slot, pixels) catch {
        return false;
    };

    return true;
}
