const std = @import("std");

const Display = @import("linux/display.zig");
const event_module = @import("../event.zig");
const geometry = @import("geometry.zig");
const interface = @import("interface.zig");
const monitor_module = @import("../monitor.zig");
const shade_module = @import("../shade.zig");
const ShadesType = @import("shades.zig").ShadesType;
const State = @import("linux/state.zig");
const surface_module = @import("../surface.zig");
const sys = @import("linux/sys.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Linux = @This();
const Listener = interface.Listener;
const Monitor = monitor_module.Monitor;
const PlatformError = interface.PlatformError;
const Rect = geometry.Rect;
const RequestError = surface_module.RequestError;
const Shade = shade_module.Shade;
const ShadeCapacityError = shade_module.CapacityError;
const ShadeOptions = Shade.Options;
const ShadeRequestError = shade_module.RequestError;
const Shades = ShadesType(State, State.submit_shade);
const Slot = interface.Slot;
const Surface = surface_module.Surface;
const SurfaceOptions = Surface.Options;

display: Display,
state: State,

pub const Options = struct {};

pub const poll_in: i16 = 1;
pub const poll_timeout_ms: i32 = 200;

comptime {
    assert(poll_in == 1);
    assert(poll_timeout_ms > 0);

    interface.assert_backend(Linux);
}

pub fn init(linux: *Linux, _: Options) PlatformError!void {
    linux.* = .{ .display = undefined, .state = .{} };
    linux.display.init(&linux.state);

    assert(linux.state.current() == .idle);

    linux.state.set_status(.starting);

    const spawned = std.Thread.spawn(.{}, pump, .{linux}) catch {
        linux.state.set_status(.idle);

        return error.ThreadSpawnFailed;
    };

    linux.state.set_thread(spawned);

    interface.wait_ready(State, &linux.state) catch |err| {
        linux.join();

        return err;
    };

    assert(linux.state.is_open());
}

pub fn deinit(linux: *Linux) void {
    assert(linux.state.get_thread() != null);

    if (linux.state.is_open()) {
        _ = linux.state.submit(.stop, 0);
    }

    linux.join();

    linux.state.clear_events();
    linux.state.clear_monitors();
    linux.state.clear_shades();
    linux.state.clear_surfaces();

    assert(!linux.state.is_open());
    assert(linux.display.selected() == .none);

    linux.* = undefined;
}

pub fn events_is_subscribed(linux: *Linux) bool {
    return linux.state.is_subscribed();
}

pub fn events_poll(linux: *Linux, list: *Event.List) u32 {
    const result = linux.state.drain(list);

    assert(result == list.count);
    assert(result <= event_module.count_max);

    return result;
}

pub fn events_subscribe(linux: *Linux, listener: Listener, context: *anyopaque) void {
    assert(linux.state.is_open());
    assert(!linux.state.is_subscribed());

    linux.state.set_subscriber(listener, context);

    assert(linux.state.is_subscribed());
}

pub fn events_unsubscribe(linux: *Linux) void {
    linux.state.set_subscriber(null, null);

    assert(!linux.state.is_subscribed());
}

pub fn monitors_list(linux: *Linux, target: *Monitor.List) u32 {
    assert(linux.state.is_open());

    const result = linux.state.copy_monitors(target);

    assert(result == target.count);

    return result;
}

pub fn shade_create(
    linux: *Linux,
    options: *const ShadeOptions,
) (ShadeCapacityError || PlatformError)!Shade {
    assert(options.is_valid());

    return Shades.create(&linux.state, options);
}

pub fn shade_destroy(linux: *Linux, shade: Shade) void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    Shades.destroy(&linux.state, shade);
}

pub fn shade_fill(
    linux: *Linux,
    shade: Shade,
    color: u32,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    try Shades.fill(&linux.state, shade, color);
}

pub fn shade_place(
    linux: *Linux,
    shade: Shade,
    rect: Rect,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(!rect.is_empty());

    try Shades.place(&linux.state, shade, rect);
}

pub fn shade_set_cursor(
    linux: *Linux,
    shade: Shade,
    cursor: Cursor,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(@backingInt(cursor) <= @backingInt(Cursor.resize_northwest_southeast));

    try Shades.set_cursor(&linux.state, shade, cursor);
}

pub fn surface_create(
    linux: *Linux,
    options: *const SurfaceOptions,
) (CapacityError || PlatformError)!Surface {
    assert(linux.state.is_open());

    const surface = try linux.state.acquire(options);

    if (!linux.state.submit(.create, surface_module.unpack(surface).index)) {
        linux.state.release(surface);

        return error.SurfaceCreateFailed;
    }

    assert(linux.state.resolve(surface) != null);

    return surface;
}

pub fn surface_destroy(linux: *Linux, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    if (linux.state.resolve(surface) == null) {
        return;
    }

    if (linux.state.is_open()) {
        _ = linux.state.submit(.destroy, surface_module.unpack(surface).index);
    }

    linux.state.release(surface);

    assert(linux.state.resolve(surface) == null);
}

pub fn surface_frame(linux: *Linux, surface: Surface) []u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return linux.state.frame_of(surface);
}

pub fn surface_hide(linux: *Linux, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    const slot = linux.state.resolve(surface) orelse return;

    slot.visible = false;

    if (linux.state.is_open()) {
        _ = linux.state.submit(.hide, surface_module.unpack(surface).index);
    }

    assert(!slot.visible);
}

pub fn surface_is_visible(linux: *const Linux, surface: Surface) bool {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return linux.state.table.is_visible(surface);
}

pub fn surface_present(linux: *Linux, surface: Surface) (PlatformError || RequestError)!void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    assert(linux.state.is_open());

    const slot = linux.state.resolve(surface) orelse return error.SurfaceUnknown;

    if (!slot.visible) {
        return;
    }

    if (!linux.state.submit(.present, surface_module.unpack(surface).index)) {
        return error.SurfacePresentFailed;
    }
}

pub fn surface_show(linux: *Linux, surface: Surface) (PlatformError || RequestError)!void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    assert(linux.state.is_open());

    const slot = linux.state.resolve(surface) orelse return error.SurfaceUnknown;

    if (!linux.state.submit(.show, surface_module.unpack(surface).index)) {
        return error.SurfaceShowFailed;
    }

    slot.visible = true;

    assert(slot.visible);
}

pub fn tint_apply(linux: *Linux, color: u32) PlatformError!void {
    assert(linux.state.is_open());

    _ = color;

    return error.TintFailed;
}

pub fn tint_clear(linux: *Linux) void {
    assert(linux.state.is_open());
}

pub fn tint_is_supported(linux: *Linux) bool {
    assert(linux.state.is_open());

    return false;
}

fn join(linux: *Linux) void {
    const present = linux.state.get_thread() orelse {
        linux.state.set_status(.idle);

        return;
    };

    present.join();

    linux.state.set_thread(null);
    linux.state.set_status(.idle);

    assert(linux.state.get_thread() == null);
}

fn pump(linux: *Linux) void {
    linux.display.open() catch {
        linux.state.set_status(.failed);

        return;
    };

    defer linux.display.close();

    const wake = sys.event_fd() catch {
        linux.state.set_status(.failed);

        return;
    };

    linux.state.set_wake(wake);
    defer {
        linux.state.set_wake(-1);

        sys.close(wake);
    }

    linux.state.set_status(.running);

    linux.loop(wake);

    linux.state.abandon();
}

fn loop(linux: *Linux, wake: sys.Fd) void {
    assert(wake >= 0);
    assert(wake != linux.display.descriptor());

    var running = true;

    while (running) {
        var fds = [_]std.os.linux.pollfd{
            .{ .fd = linux.display.descriptor(), .events = poll_in, .revents = 0 },
            .{ .fd = wake, .events = poll_in, .revents = 0 },
        };

        const ready = sys.wait(&fds, poll_timeout_ms) catch {
            break;
        };

        if (ready > 0) {
            if (fds[0].revents != 0) {
                linux.display.pump();

                if (linux.display.take_restack()) linux.restack_surfaces();
            }

            if (fds[1].revents != 0) {
                sys.consume(wake);
            }
        }

        running = linux.serve();

        if (!linux.display.is_live()) {
            break;
        }
    }
}

fn serve(linux: *Linux) bool {
    const request = linux.state.take() orelse return true;

    if (request.kind == .stop) {
        linux.state.complete(true);

        return false;
    }

    const succeeded = if (request.kind.is_shade())
        linux.perform_shade(request.kind, request.index)
    else
        linux.perform(request.kind, request.index);

    linux.state.complete(succeeded);

    return true;
}

fn perform_shade(linux: *Linux, kind: State.Request, index: u16) bool {
    assert(kind.is_shade());
    assert(index < shade_module.count_max);

    const slot = linux.state.shade_at(index);

    switch (kind) {
        .shade_create => {
            linux.display.shade_create(index, &slot) catch {
                return false;
            };

            linux.restack_surfaces();
        },
        .shade_destroy => {
            linux.display.shade_destroy(index);
        },
        .shade_fill => {
            linux.display.shade_fill(index, slot.color) catch {
                return false;
            };
        },
        .shade_place => {
            linux.display.shade_place(index, slot.rect) catch {
                return false;
            };
        },
        .shade_cursor => {
            linux.display.shade_cursor(index, slot.cursor) catch {
                return false;
            };
        },
        .none, .create, .destroy, .show, .hide, .present, .stop => unreachable,
    }

    return true;
}

fn perform(linux: *Linux, kind: State.Request, index: u16) bool {
    assert(kind != .none);
    assert(kind != .stop);
    assert(!kind.is_shade());
    assert(index < surface_module.count_max);

    const slot = linux.state.slot_at(index);

    switch (kind) {
        .create => {
            linux.display.create(index, slot) catch {
                return false;
            };
        },
        .destroy => {
            linux.display.destroy(index);
        },
        .show => {
            linux.display.show(index, slot) catch {
                return false;
            };

            return linux.publish_frame(index, slot);
        },
        .hide => {
            linux.display.hide(index);
        },
        .present => {
            return linux.publish_frame(index, slot);
        },
        else => {
            return false;
        },
    }

    return true;
}

fn restack_surfaces(linux: *Linux) void {
    for (0..surface_module.count_max) |position| {
        const index: u16 = @intCast(position);
        if (!linux.display.is_mapped(index)) continue;

        const slot = linux.state.slot_at(index);

        linux.display.hide(index);

        linux.display.show(index, slot) catch {
            continue;
        };

        _ = linux.publish_frame(index, slot);

        assert(linux.display.is_mapped(index));
    }
}

fn publish_frame(linux: *Linux, index: u16, slot: *const Slot) bool {
    if (!linux.display.is_mapped(index)) {
        return true;
    }

    const pixels = linux.state.frame_at(index);

    linux.display.present(index, slot, pixels) catch {
        return false;
    };

    return true;
}
