const std = @import("std");

const kalymma = @import("root.zig");

const EventList = kalymma.EventList;
const SurfaceConfig = kalymma.SurfaceConfig;

const testing = std.testing;

const widget = SurfaceConfig{
    .anchor = .bottom_right,
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

test {
    _ = @import("platform/windows/window.zig");
}

fn open() !bool {
    kalymma.runtime.open(.{ .name = "kalymma" }) catch |err| {
        if (err == kalymma.RuntimeError.Unavailable) {
            return false;
        }

        return err;
    };

    return true;
}

test "closing an unopened runtime is inert" {
    kalymma.runtime.close();

    try testing.expect(!kalymma.runtime.is_open());
}

test "a closed runtime refuses every surface operation" {
    try testing.expect(!kalymma.runtime.is_open());
    try testing.expectError(kalymma.SurfaceError.NotOpen, kalymma.surface.create(widget));
    try testing.expectError(kalymma.EventError.NotOpen, kalymma.events.subscribe(on_wake, null));
}

test "the runtime opens a message pump and reports a second open" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    try testing.expect(kalymma.runtime.is_open());

    try testing.expectError(
        kalymma.RuntimeError.AlreadyOpen,
        kalymma.runtime.open(.{ .name = "kalymma" }),
    );
}

test "a created surface starts hidden and owns a frame of its own size" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    const handle = try kalymma.surface.create(widget);
    defer kalymma.surface.destroy(handle);

    try testing.expect(handle.is_valid());
    try testing.expect(!kalymma.surface.is_visible(handle));
    try testing.expectEqual(@as(usize, 380 * 220), kalymma.surface.frame(handle).len);
    try testing.expectEqual(@as(u32, 1), kalymma.surface.scale(handle));
}

test "a shown surface presents its frame and hides again" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    const handle = try kalymma.surface.create(widget);
    defer kalymma.surface.destroy(handle);

    const pixels = kalymma.surface.frame(handle);

    @memset(pixels, 0xFF1A1A1A);

    try kalymma.surface.show(handle);

    try testing.expect(kalymma.surface.is_visible(handle));

    try kalymma.surface.present(handle);

    kalymma.surface.hide(handle);

    try testing.expect(!kalymma.surface.is_visible(handle));
}

test "presenting a hidden surface is inert rather than an error" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    const handle = try kalymma.surface.create(widget);
    defer kalymma.surface.destroy(handle);

    try kalymma.surface.present(handle);
}

test "a destroyed surface is gone from every accessor" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    const handle = try kalymma.surface.create(widget);

    kalymma.surface.destroy(handle);

    try testing.expect(!kalymma.surface.is_visible(handle));
    try testing.expectEqual(@as(usize, 0), kalymma.surface.frame(handle).len);
    try testing.expectError(kalymma.SurfaceError.NotFound, kalymma.surface.show(handle));
}

test "the surface table fills to its bound and then reports the overflow" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    var index: u32 = 0;

    while (index < kalymma.surfaces_max) : (index += 1) {
        _ = try kalymma.surface.create(widget);
    }

    try testing.expectError(kalymma.SurfaceError.TooMany, kalymma.surface.create(widget));
}

test "a subscriber starts, reports itself, and stops" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    try testing.expect(!kalymma.events.is_subscribed());

    try kalymma.events.subscribe(on_wake, null);

    try testing.expect(kalymma.events.is_subscribed());

    try testing.expectError(
        kalymma.EventError.AlreadySubscribed,
        kalymma.events.subscribe(on_wake, null),
    );

    kalymma.events.unsubscribe();

    try testing.expect(!kalymma.events.is_subscribed());
}

test "closing the runtime drops the subscriber and every surface" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    const handle = try kalymma.surface.create(widget);

    try kalymma.events.subscribe(on_wake, null);

    kalymma.runtime.close();

    try testing.expect(!kalymma.events.is_subscribed());
    try testing.expectEqual(@as(usize, 0), kalymma.surface.frame(handle).len);
}

test "an empty queue drains to nothing" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer kalymma.runtime.close();

    var list = EventList.init();

    try testing.expectEqual(@as(u32, 0), kalymma.events.poll(&list));
    try testing.expectEqual(@as(u32, 0), kalymma.events.drops());
}

var wakes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn on_wake(_: ?*anyopaque) void {
    _ = wakes.fetchAdd(1, .seq_cst);
}
