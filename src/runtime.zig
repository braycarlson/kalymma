const std = @import("std");

const event_module = @import("event.zig");
const monitor_module = @import("monitor.zig");
const platform = @import("platform.zig");
const shade_module = @import("shade.zig");
const surface_module = @import("surface.zig");

const assert = std.debug.assert;

const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Monitor = monitor_module.Monitor;
const PlatformError = platform.PlatformError;
const Rect = platform.Rect;
const Shade = shade_module.Shade;
const ShadeCapacityError = shade_module.CapacityError;
const ShadeRequestError = shade_module.RequestError;
const Surface = surface_module.Surface;
const SurfaceCapacityError = surface_module.CapacityError;
const SurfaceRequestError = surface_module.RequestError;

const frame_pixels_max: u32 = surface_module.width_pixels_max * surface_module.height_pixels_max;

pub fn RuntimeType(comptime Platform: type) type {
    platform.assert_backend(Platform);

    return struct {
        platform: Platform,

        const Runtime = @This();
        pub const Options = Platform.Options;

        pub fn init(runtime: *Runtime, options: Options) PlatformError!void {
            try runtime.platform.init(options);

            assert(!runtime.platform.events_is_subscribed());
        }

        pub fn deinit(runtime: *Runtime) void {
            runtime.platform.deinit();
        }

        pub fn events_poll(runtime: *Runtime, list: *Event.List) u32 {
            const result = runtime.platform.events_poll(list);

            assert(result == list.count);
            assert(result <= event_module.count_max);

            return result;
        }

        pub fn events_subscribe(
            runtime: *Runtime,
            comptime Owner: type,
            owner: *Owner,
            comptime callback: fn (*Owner) void,
        ) void {
            assert(!runtime.platform.events_is_subscribed());

            const Listener = ListenerType(Owner, callback);

            runtime.platform.events_subscribe(Listener.invoke, owner);

            assert(runtime.platform.events_is_subscribed());
        }

        pub fn events_unsubscribe(runtime: *Runtime) void {
            runtime.platform.events_unsubscribe();

            assert(!runtime.platform.events_is_subscribed());
        }

        pub fn monitors_list(runtime: *Runtime, target: *Monitor.List) u32 {
            const result = runtime.platform.monitors_list(target);

            assert(result == target.count);
            assert(result <= monitor_module.count_max);

            return result;
        }

        pub fn shade_create(
            runtime: *Runtime,
            options: Shade.Options,
        ) (ShadeCapacityError || PlatformError || ShadeRequestError)!Shade {
            try options.validate();

            const result = try runtime.platform.shade_create(&options);

            assert(shade_module.unpack(result).generation > 0);
            assert(shade_module.unpack(result).index < shade_module.count_max);

            return result;
        }

        pub fn shade_destroy(runtime: *Runtime, shade: Shade) void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(shade_module.unpack(shade).index < shade_module.count_max);

            runtime.platform.shade_destroy(shade);
        }

        pub fn shade_fill(
            runtime: *Runtime,
            shade: Shade,
            color: u32,
        ) (PlatformError || ShadeRequestError)!void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(shade_module.unpack(shade).index < shade_module.count_max);

            try runtime.platform.shade_fill(shade, color);
        }

        pub fn shade_place(
            runtime: *Runtime,
            shade: Shade,
            rect: Rect,
        ) (ShadeCapacityError || PlatformError || ShadeRequestError)!void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(shade_module.unpack(shade).index < shade_module.count_max);

            try shade_module.validate_rect(rect);
            try runtime.platform.shade_place(shade, rect);
        }

        pub fn shade_set_cursor(
            runtime: *Runtime,
            shade: Shade,
            cursor: Cursor,
        ) (PlatformError || ShadeRequestError)!void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(shade_module.unpack(shade).index < shade_module.count_max);

            try runtime.platform.shade_set_cursor(shade, cursor);
        }

        pub fn surface_create(
            runtime: *Runtime,
            options: Surface.Options,
        ) (SurfaceCapacityError || PlatformError || SurfaceRequestError)!Surface {
            try options.validate();

            const result = try runtime.platform.surface_create(&options);

            assert(!runtime.platform.surface_is_visible(result));
            assert(runtime.platform.surface_frame(result).len == options.width * options.height);

            return result;
        }

        pub fn surface_destroy(runtime: *Runtime, surface: Surface) void {
            assert(surface_module.unpack(surface).generation > 0);
            assert(surface_module.unpack(surface).index < surface_module.count_max);

            runtime.platform.surface_destroy(surface);

            assert(!runtime.platform.surface_is_visible(surface));
            assert(runtime.platform.surface_frame(surface).len == 0);
        }

        pub fn surface_frame(runtime: *Runtime, surface: Surface) []u32 {
            assert(surface_module.unpack(surface).generation > 0);
            assert(surface_module.unpack(surface).index < surface_module.count_max);

            const result = runtime.platform.surface_frame(surface);

            assert(result.len <= frame_pixels_max);

            return result;
        }

        pub fn surface_hide(runtime: *Runtime, surface: Surface) void {
            assert(surface_module.unpack(surface).generation > 0);
            assert(surface_module.unpack(surface).index < surface_module.count_max);

            runtime.platform.surface_hide(surface);

            assert(!runtime.platform.surface_is_visible(surface));
        }

        pub fn surface_is_visible(runtime: *const Runtime, surface: Surface) bool {
            assert(surface_module.unpack(surface).generation > 0);
            assert(surface_module.unpack(surface).index < surface_module.count_max);

            return runtime.platform.surface_is_visible(surface);
        }

        pub fn surface_present(
            runtime: *Runtime,
            surface: Surface,
        ) (PlatformError || SurfaceRequestError)!void {
            assert(surface_module.unpack(surface).generation > 0);
            assert(surface_module.unpack(surface).index < surface_module.count_max);

            try runtime.platform.surface_present(surface);
        }

        pub fn surface_show(
            runtime: *Runtime,
            surface: Surface,
        ) (PlatformError || SurfaceRequestError)!void {
            assert(surface_module.unpack(surface).generation > 0);
            assert(surface_module.unpack(surface).index < surface_module.count_max);

            try runtime.platform.surface_show(surface);

            assert(runtime.platform.surface_is_visible(surface));
        }

        pub fn tint_apply(runtime: *Runtime, color: u32) PlatformError!void {
            assert(runtime.platform.tint_is_supported());

            try runtime.platform.tint_apply(color);
        }

        pub fn tint_clear(runtime: *Runtime) void {
            runtime.platform.tint_clear();
        }

        pub fn tint_is_supported(runtime: *Runtime) bool {
            return runtime.platform.tint_is_supported();
        }
    };
}

fn ListenerType(comptime Owner: type, comptime callback: fn (*Owner) void) type {
    return struct {
        fn invoke(context: *anyopaque) void {
            const owner: *Owner = @ptrCast(@alignCast(context));

            callback(owner);
        }
    };
}

const testing = std.testing;

const FakeRuntime = RuntimeType(platform.Fake);

const Waker = struct {
    wakes: u32 = 0,

    fn on_wake(waker: *Waker) void {
        waker.wakes += 1;
    }
};

const widget = Surface.Options{
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

fn open() !*FakeRuntime {
    const runtime = try testing.allocator.create(FakeRuntime);
    errdefer testing.allocator.destroy(runtime);

    try runtime.init(.{});

    return runtime;
}

fn close(runtime: *FakeRuntime) void {
    runtime.deinit();
    testing.allocator.destroy(runtime);
}

test RuntimeType {
    const runtime = try testing.allocator.create(FakeRuntime);
    defer testing.allocator.destroy(runtime);

    try runtime.init(.{});
    defer runtime.deinit();

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    @memset(runtime.surface_frame(status), 0xFF102030);

    try runtime.surface_show(status);
    try runtime.surface_present(status);

    try testing.expect(runtime.surface_is_visible(status));
    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.surface_present));
}

test "init opens the platform once" {
    const runtime = try open();
    defer close(runtime);

    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.init));
    try testing.expect(!runtime.platform.events_is_subscribed());
}

test "a deinitialized runtime initializes again from nothing" {
    const runtime = try open();
    defer close(runtime);

    _ = try runtime.surface_create(widget);

    runtime.deinit();

    try runtime.init(.{});

    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.init));
    try testing.expectEqual(@as(u32, 0), runtime.platform.table.count());
}

test "a display that will not open fails the init and leaves the runtime free to open again" {
    const runtime = try testing.allocator.create(FakeRuntime);
    defer testing.allocator.destroy(runtime);

    try testing.expectError(error.DisplayUnavailable, runtime.init(.{ .fault = .init }));

    try runtime.init(.{});
    defer runtime.deinit();

    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.init));
}

test "events_poll drains the injected events in order and then reports nothing" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    runtime.platform.inject(surface, .{ .pointer_move = .{ .x = 12, .y = 34 } });
    runtime.platform.inject(surface, .{ .key_down = .escape });

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 2), runtime.events_poll(&list));
    try testing.expectEqual(@as(i32, 12), list.slice()[0].input.pointer_move.x);
    try testing.expectEqual(surface, list.slice()[1].source.surface);
    try testing.expectEqual(@as(u32, 0), runtime.events_poll(&list));
}

test "events_subscribe wakes the owner for each injected event" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    var waker = Waker{};

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);

    runtime.platform.inject(surface, .{ .focus_lost = {} });

    try testing.expectEqual(@as(u32, 1), waker.wakes);
}

test "events_unsubscribe stops the wakes and leaves the queue to drain" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    var waker = Waker{};

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);
    runtime.events_unsubscribe();

    runtime.platform.inject(surface, .{ .pointer_leave = {} });

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 0), waker.wakes);
    try testing.expectEqual(@as(u32, 1), runtime.events_poll(&list));
}

test "a runtime opened again after deinit has no subscriber and no surface" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);

    var waker = Waker{};

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);
    runtime.deinit();

    try runtime.init(.{});

    try testing.expect(!runtime.platform.events_is_subscribed());
    try testing.expectEqual(@as(usize, 0), runtime.surface_frame(surface).len);
}

test "an overflowing queue keeps the newest events" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    var index: u32 = 0;

    while (index < event_module.count_max + 2) : (index += 1) {
        runtime.platform.inject(surface, .{ .pointer_move = .{ .x = @intCast(index), .y = 0 } });
    }

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 2), runtime.platform.drops());
    try testing.expectEqual(event_module.count_max, runtime.events_poll(&list));
    try testing.expectEqual(@as(i32, 2), list.slice()[0].input.pointer_move.x);
}
