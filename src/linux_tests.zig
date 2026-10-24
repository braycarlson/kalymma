const std = @import("std");

const display = @import("platform/linux/display.zig");
const event_module = @import("event.zig");
const platform = @import("platform.zig");
const surface_module = @import("surface.zig");

const backend = platform.backend;

const Event = event_module.Event;
const Options = surface_module.Options;
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
    _ = @import("platform/linux/sys.zig");
    _ = @import("platform/linux/wayland/client.zig");
    _ = @import("platform/linux/wayland/protocol.zig");
    _ = @import("platform/linux/wayland/wire.zig");
    _ = @import("platform/linux/x11/auth.zig");
    _ = @import("platform/linux/x11/client.zig");
    _ = @import("platform/linux/x11/protocol.zig");
}

fn open() !bool {
    backend.runtime.open() catch |err| switch (err) {
        error.DisplayUnavailable => return false,
        else => return err,
    };

    return true;
}

test "closing an unopened runtime is inert" {
    backend.runtime.close();

    try testing.expect(!backend.runtime.is_open());
}

test "the runtime picks a display server" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    try testing.expect(backend.runtime.is_open());
    try testing.expect(display.selected() != .none);
    try testing.expect(display.descriptor() >= 0);
}

test "a created surface starts hidden and owns a frame of its own size" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    try testing.expect(!surface_module.is_visible(surface));
    try testing.expectEqual(@as(usize, 380 * 220), surface_module.frame(surface).len);
}

test "a shown surface presents its frame and hides again" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    @memset(surface_module.frame(surface), 0xFF1A1A1A);

    try surface_module.show(surface);

    try testing.expect(surface_module.is_visible(surface));

    try surface_module.present(surface);

    surface_module.hide(surface);

    try testing.expect(!surface_module.is_visible(surface));
}

test "presenting a hidden surface is inert rather than an error" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    try surface_module.present(surface);
}

test "a destroyed surface is gone from every accessor" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const surface = try surface_module.create(widget);

    surface_module.destroy(surface);

    try testing.expect(!surface_module.is_visible(surface));
    try testing.expectEqual(@as(usize, 0), surface_module.frame(surface).len);
    try testing.expectError(error.SurfaceUnknown, surface_module.show(surface));
}

test "the surface table fills to its bound and then reports the overflow" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var index: u32 = 0;

    while (index < surface_module.surface_count_max) : (index += 1) {
        _ = try surface_module.create(widget);
    }

    try testing.expectError(error.SurfacesExhausted, surface_module.create(widget));
}

test "a configuration outside the contract bounds never reaches the display" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const oversized = Options{
        .height = 220,
        .name = "widget",
        .width = surface_module.width_pixels_max + 1,
    };

    try testing.expectError(error.SurfaceTooLarge, surface_module.create(oversized));
}

test "a subscriber starts, reports itself, and stops" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var wakes = std.atomic.Value(u32).init(0);

    try testing.expect(!backend.events.is_subscribed());

    backend.events.subscribe(on_wake, &wakes);

    try testing.expect(backend.events.is_subscribed());

    backend.events.unsubscribe();

    try testing.expect(!backend.events.is_subscribed());
}

test "closing the runtime drops the subscriber and every surface" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    var wakes = std.atomic.Value(u32).init(0);

    const surface = try surface_module.create(widget);

    backend.events.subscribe(on_wake, &wakes);
    backend.runtime.close();

    try testing.expect(!backend.events.is_subscribed());
    try testing.expectEqual(@as(usize, 0), surface_module.frame(surface).len);
}

test "an empty queue drains to nothing" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 0), backend.events.poll(&list));
}

fn on_wake(context: *anyopaque) void {
    const wakes: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));

    _ = wakes.fetchAdd(1, .seq_cst);
}
