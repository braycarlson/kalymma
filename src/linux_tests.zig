const std = @import("std");

const event_module = @import("event.zig");
const Linux = @import("platform/linux.zig");
const monitor_module = @import("monitor.zig");
const platform = @import("platform.zig");
const RuntimeType = @import("runtime.zig").RuntimeType;
const shade_module = @import("shade.zig");
const surface_module = @import("surface.zig");

const Event = event_module.Event;
const Monitor = monitor_module.Monitor;
const Options = surface_module.Surface.Options;
const Rect = platform.Rect;
const Runtime = RuntimeType(Linux);
const testing = std.testing;

const widget = Options{
    .anchor = .bottom_right,
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

test {
    _ = @import("platform/linux/display.zig");
    _ = @import("platform/linux/state.zig");
    _ = @import("platform/linux/sys.zig");
    _ = @import("platform/linux/wayland/client.zig");
    _ = @import("platform/linux/wayland/protocol.zig");
    _ = @import("platform/linux/wayland/wire.zig");
    _ = @import("platform/linux/x11/auth.zig");
    _ = @import("platform/linux/x11/client.zig");
    _ = @import("platform/linux/x11/cursor.zig");
    _ = @import("platform/linux/x11/protocol.zig");
}

fn open() !*Runtime {
    const runtime = try testing.allocator.create(Runtime);
    errdefer testing.allocator.destroy(runtime);

    runtime.init(.{}) catch |err| switch (err) {
        error.DisplayUnavailable => return error.SkipZigTest,
        else => return err,
    };

    return runtime;
}

fn close(runtime: *Runtime) void {
    runtime.deinit();
    testing.allocator.destroy(runtime);
}

test "the runtime picks a display server" {
    const runtime = try open();
    defer close(runtime);

    try testing.expect(runtime.platform.state.is_open());
    try testing.expect(runtime.platform.display.selected() != .none);
    try testing.expect(runtime.platform.display.descriptor() >= 0);
}

test "a created surface starts hidden and owns a frame of its own size" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    try testing.expect(!runtime.surface_is_visible(surface));
    try testing.expectEqual(@as(usize, 380 * 220), runtime.surface_frame(surface).len);
}

test "a shown surface presents its frame and hides again" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    @memset(runtime.surface_frame(surface), 0xFF1A1A1A);

    try runtime.surface_show(surface);

    try testing.expect(runtime.surface_is_visible(surface));

    try runtime.surface_present(surface);

    runtime.surface_hide(surface);

    try testing.expect(!runtime.surface_is_visible(surface));
}

test "presenting a hidden surface is inert rather than an error" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);
    defer runtime.surface_destroy(surface);

    try runtime.surface_present(surface);
}

test "a destroyed surface is gone from every accessor" {
    const runtime = try open();
    defer close(runtime);

    const surface = try runtime.surface_create(widget);

    runtime.surface_destroy(surface);

    try testing.expect(!runtime.surface_is_visible(surface));
    try testing.expectEqual(@as(usize, 0), runtime.surface_frame(surface).len);
    try testing.expectError(error.SurfaceUnknown, runtime.surface_show(surface));
}

test "the surface table fills to its bound and then reports the overflow" {
    const runtime = try open();
    defer close(runtime);

    var index: u32 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        _ = try runtime.surface_create(widget);
    }

    try testing.expectError(error.SurfacesExhausted, runtime.surface_create(widget));
}

test "a configuration outside the interface bounds never reaches the display" {
    const runtime = try open();
    defer close(runtime);

    const oversized = Options{
        .height = 220,
        .name = "widget",
        .width = surface_module.width_pixels_max + 1,
    };

    try testing.expectError(error.SurfaceTooLarge, runtime.surface_create(oversized));
}

test "a subscriber starts, reports itself, and stops" {
    const runtime = try open();
    defer close(runtime);

    var wakes = std.atomic.Value(u32).init(0);

    try testing.expect(!runtime.platform.events_is_subscribed());

    runtime.platform.events_subscribe(on_wake, &wakes);

    try testing.expect(runtime.platform.events_is_subscribed());

    runtime.platform.events_unsubscribe();

    try testing.expect(!runtime.platform.events_is_subscribed());
}

test "a runtime opened again after deinit has no subscriber and no surface" {
    const runtime = try open();
    defer testing.allocator.destroy(runtime);

    var wakes = std.atomic.Value(u32).init(0);

    const surface = runtime.surface_create(widget) catch |err| {
        runtime.deinit();

        return err;
    };

    runtime.platform.events_subscribe(on_wake, &wakes);
    runtime.deinit();

    try runtime.init(.{});
    defer runtime.deinit();

    try testing.expect(!runtime.platform.events_is_subscribed());
    try testing.expectEqual(@as(usize, 0), runtime.surface_frame(surface).len);
}

test "an empty queue drains to nothing" {
    const runtime = try open();
    defer close(runtime);

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 0), runtime.platform.events_poll(&list));
}

fn monitor_first(runtime: *Runtime) !Rect {
    var monitors = Monitor.List.init();

    if (runtime.monitors_list(&monitors) == 0) {
        return error.NoMonitor;
    }

    return monitors.slice()[0].rect;
}

test "the display reports every monitor with a name and a usable rectangle" {
    const runtime = try open();
    defer close(runtime);

    var monitors = Monitor.List.init();
    var primaries: u32 = 0;

    try testing.expect(runtime.monitors_list(&monitors) > 0);

    for (monitors.slice()) |*monitor| {
        try testing.expect(!monitor.rect.is_empty());
        try testing.expect(monitor.get_name().len > 0);

        if (monitor.primary) primaries += 1;
    }

    try testing.expect(primaries <= 1);
}

test "a shade covers a corner, changes level, moves, and goes away" {
    const runtime = try open();
    defer close(runtime);

    const screen = try monitor_first(runtime);
    const corner = Rect{ .height = 120, .width = 160, .x = screen.x, .y = screen.y };
    const moved = Rect{ .height = 80, .width = 100, .x = screen.x + 20, .y = screen.y + 20 };

    const shade = try runtime.shade_create(.{ .color = 0x40000000, .rect = corner });

    try runtime.shade_fill(shade, 0x80000000);
    try runtime.shade_place(shade, moved);

    runtime.shade_destroy(shade);

    try testing.expectError(error.ShadeUnknown, runtime.shade_fill(shade, 0x80000000));
    try testing.expectError(error.ShadeUnknown, runtime.shade_place(shade, corner));
}

test "an interactive shade takes the pointer and lets it go when destroyed" {
    const runtime = try open();
    defer close(runtime);

    const screen = try monitor_first(runtime);
    const corner = Rect{ .height = 60, .width = 60, .x = screen.x, .y = screen.y };

    const shade = try runtime.shade_create(.{
        .color = 0x20000000,
        .interactive = true,
        .rect = corner,
    });

    runtime.shade_destroy(shade);

    var list = Event.List.init();

    _ = runtime.platform.events_poll(&list);

    for (list.slice()) |event| {
        if (event.source == .shade) try testing.expect(event.source.shade == shade);
    }
}

test "the shade table fills to its bound and reports the overflow" {
    const runtime = try open();
    defer close(runtime);

    const screen = try monitor_first(runtime);
    const corner = Rect{ .height = 40, .width = 40, .x = screen.x, .y = screen.y };

    var index: u32 = 0;

    while (index < shade_module.count_max) : (index += 1) {
        _ = try runtime.shade_create(.{ .color = 0x10000000, .rect = corner });
    }

    try testing.expectError(
        error.ShadesExhausted,
        runtime.shade_create(.{ .color = 0x10000000, .rect = corner }),
    );
}

test "the tint reports itself unsupported and refuses a direct request" {
    const runtime = try open();
    defer close(runtime);

    try testing.expect(!runtime.tint_is_supported());

    runtime.tint_clear();

    try testing.expectError(error.TintFailed, runtime.platform.tint_apply(0x80000000));
}

fn on_wake(context: *anyopaque) void {
    const wakes: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));

    _ = wakes.fetchAdd(1, .seq_cst);
}
