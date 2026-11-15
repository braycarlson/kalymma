const std = @import("std");

const event_module = @import("../event.zig");
const geometry = @import("geometry.zig");
const interface = @import("interface.zig");
const monitor_module = @import("../monitor.zig");
const shade_module = @import("../shade.zig");
const ShadesType = @import("shades.zig").ShadesType;
const State = @import("windows/state.zig");
const surface_module = @import("../surface.zig");
const win32 = @import("windows/win32.zig");
const window = @import("windows/window.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Listener = interface.Listener;
const Monitor = monitor_module.Monitor;
const PlatformError = interface.PlatformError;
const Rect = geometry.Rect;
const RequestError = surface_module.RequestError;
const Shade = shade_module.Shade;
const ShadeCapacityError = shade_module.CapacityError;
const ShadeOptions = Shade.Options;
const ShadeRequest = interface.ShadeRequest;
const ShadeRequestError = shade_module.RequestError;
const Shades = ShadesType(State, dispatch_shade);
const Surface = surface_module.Surface;
const SurfaceOptions = Surface.Options;
const Windows = @This();

state: State,

pub const Options = struct {};

comptime {
    interface.assert_backend(Windows);
}

pub fn init(windows: *Windows, _: Options) PlatformError!void {
    windows.* = .{ .state = .{} };

    assert(windows.state.current() == .idle);

    if (!window.is_station_visible()) {
        return error.DisplayUnavailable;
    }

    windows.state.set_status(.starting);

    const spawned = std.Thread.spawn(.{}, pump, .{&windows.state}) catch {
        windows.state.set_status(.idle);

        return error.ThreadSpawnFailed;
    };

    windows.state.set_thread(spawned);

    interface.wait_ready(State, &windows.state) catch |err| {
        windows.stop();

        return err;
    };

    assert(windows.state.is_open());
}

pub fn deinit(windows: *Windows) void {
    assert(windows.state.get_thread() != null);

    windows.stop();

    windows.state.clear_events();
    windows.state.clear_monitors();
    windows.state.clear_shades();
    windows.state.clear_surfaces();

    assert(!windows.state.is_open());
    assert(windows.state.get_controller() == null);

    windows.* = undefined;
}

pub fn events_is_subscribed(windows: *Windows) bool {
    return windows.state.is_subscribed();
}

pub fn events_poll(windows: *Windows, list: *Event.List) u32 {
    const result = windows.state.drain(list);

    assert(result == list.count);
    assert(result <= event_module.count_max);

    return result;
}

pub fn events_subscribe(windows: *Windows, listener: Listener, context: *anyopaque) void {
    assert(windows.state.is_open());
    assert(!windows.state.is_subscribed());

    windows.state.set_subscriber(listener, context);

    assert(windows.state.is_subscribed());
}

pub fn events_unsubscribe(windows: *Windows) void {
    windows.state.set_subscriber(null, null);

    assert(!windows.state.is_subscribed());
}

pub fn monitors_list(windows: *Windows, target: *Monitor.List) u32 {
    assert(windows.state.is_open());

    const result = windows.state.copy_monitors(target);

    assert(result == target.count);

    return result;
}

pub fn shade_create(
    windows: *Windows,
    options: *const ShadeOptions,
) (ShadeCapacityError || PlatformError)!Shade {
    assert(options.is_valid());

    return Shades.create(&windows.state, options);
}

pub fn shade_destroy(windows: *Windows, shade: Shade) void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    Shades.destroy(&windows.state, shade);
}

pub fn shade_fill(
    windows: *Windows,
    shade: Shade,
    color: u32,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    try Shades.fill(&windows.state, shade, color);
}

pub fn shade_place(
    windows: *Windows,
    shade: Shade,
    rect: Rect,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(!rect.is_empty());

    try Shades.place(&windows.state, shade, rect);
}

pub fn shade_set_cursor(
    windows: *Windows,
    shade: Shade,
    cursor: Cursor,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(@backingInt(cursor) <= @backingInt(Cursor.resize_northwest_southeast));

    try Shades.set_cursor(&windows.state, shade, cursor);
}

pub fn surface_create(
    windows: *Windows,
    options: *const SurfaceOptions,
) (CapacityError || PlatformError)!Surface {
    assert(windows.state.is_open());

    const surface = try windows.state.acquire(options);

    if (!dispatch(&windows.state, window.message_create, surface_module.unpack(surface).index)) {
        windows.state.release(surface);

        return error.SurfaceCreateFailed;
    }

    assert(windows.state.resolve(surface) != null);

    return surface;
}

pub fn surface_destroy(windows: *Windows, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    if (windows.state.resolve(surface) == null) {
        return;
    }

    _ = dispatch(&windows.state, window.message_destroy, surface_module.unpack(surface).index);

    windows.state.release(surface);

    assert(windows.state.resolve(surface) == null);
}

pub fn surface_frame(windows: *Windows, surface: Surface) []u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return windows.state.frame_of(surface);
}

pub fn surface_hide(windows: *Windows, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    if (windows.state.resolve(surface) == null) {
        return;
    }

    _ = dispatch(&windows.state, window.message_hide, surface_module.unpack(surface).index);
}

pub fn surface_is_visible(windows: *const Windows, surface: Surface) bool {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return windows.state.table.is_visible(surface);
}

pub fn surface_present(windows: *Windows, surface: Surface) (PlatformError || RequestError)!void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    assert(windows.state.is_open());

    const slot = windows.state.resolve(surface) orelse return error.SurfaceUnknown;

    if (!slot.visible) {
        return;
    }

    if (!dispatch(&windows.state, window.message_present, surface_module.unpack(surface).index)) {
        return error.SurfacePresentFailed;
    }
}

pub fn surface_show(windows: *Windows, surface: Surface) (PlatformError || RequestError)!void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(windows.state.is_open());

    if (windows.state.resolve(surface) == null) {
        return error.SurfaceUnknown;
    }

    if (!dispatch(&windows.state, window.message_show, surface_module.unpack(surface).index)) {
        return error.SurfaceShowFailed;
    }
}

pub fn tint_apply(windows: *Windows, color: u32) PlatformError!void {
    assert(windows.state.is_open());

    if (!dispatch_tint(&windows.state, window.message_tint_apply, color)) {
        return error.TintFailed;
    }
}

pub fn tint_clear(windows: *Windows) void {
    assert(windows.state.is_open());

    _ = dispatch_tint(&windows.state, window.message_tint_clear, 0);
}

pub fn tint_is_supported(windows: *Windows) bool {
    assert(windows.state.is_open());

    return dispatch_tint(&windows.state, window.message_tint_probe, 0);
}

fn dispatch(state: *State, code: u32, index: u16) bool {
    assert(code >= window.message_create);
    assert(code <= window.message_present);
    assert(index < surface_module.count_max);

    const controller = state.get_controller() orelse return false;
    const result = win32.SendMessageW(controller, code, index, 0);

    return result == window.result_ok;
}

fn dispatch_shade(state: *State, request: ShadeRequest, index: u16) bool {
    assert(index < shade_module.count_max);

    const code = switch (request) {
        .create => window.message_shade_create,
        .destroy => window.message_shade_destroy,
        .fill => window.message_shade_fill,
        .place => window.message_shade_place,
        .cursor => window.message_shade_cursor,
    };

    const controller = state.get_controller() orelse return false;
    const result = win32.SendMessageW(controller, code, index, 0);

    return result == window.result_ok;
}

fn dispatch_tint(state: *State, code: u32, color: u32) bool {
    assert(code >= window.message_tint_apply);
    assert(code <= window.message_tint_probe);

    const controller = state.get_controller() orelse return false;
    const result = win32.SendMessageW(controller, code, color, 0);

    return result == window.result_ok;
}

fn pump(state: *State) void {
    if (!window.register_classes()) {
        state.set_status(.failed);

        return;
    }

    defer window.unregister_classes();

    const controller = window.create_controller(state) orelse {
        state.set_status(.failed);

        return;
    };

    state.set_controller(controller);
    defer {
        window.release_windows(state);
        state.get_magnifier().release();
        state.set_controller(null);

        _ = win32.DestroyWindow(controller);
    }

    window.refresh_monitors(state);
    state.set_status(.running);

    var message = win32.MSG{};

    while (win32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&message);
        _ = win32.DispatchMessageW(&message);
    }
}

fn stop(windows: *Windows) void {
    const present = windows.state.get_thread() orelse {
        windows.state.set_status(.idle);

        return;
    };

    if (windows.state.get_controller()) |handle| {
        _ = win32.PostMessageW(handle, window.message_stop, 0, 0);
    }

    present.join();

    windows.state.set_thread(null);
    windows.state.set_status(.idle);

    assert(windows.state.get_thread() == null);
}
