const std = @import("std");

const kalymma = @import("root.zig");
const state = @import("platform/mock/state.zig");

const EventList = kalymma.EventList;
const Handle = kalymma.Handle;
const SurfaceConfig = kalymma.SurfaceConfig;
const testing = std.testing;

const widget = SurfaceConfig{
    .anchor = .bottom_right,
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

fn kind_of(event: kalymma.Event) kalymma.InputKind {
    return event.input;
}

var wakes: u32 = 0;

fn on_wake(_: ?*anyopaque) void {
    wakes += 1;
}

fn open() !void {
    state.reset();

    wakes = 0;

    try kalymma.runtime.open(.{ .name = "mute" });
}

fn surface_of() !Handle {
    return try kalymma.surface.create(widget);
}

test "a closed runtime refuses every surface operation" {
    state.reset();

    try testing.expect(!kalymma.runtime.is_open());
    try testing.expectError(kalymma.SurfaceError.NotOpen, kalymma.surface.create(widget));
    try testing.expectError(kalymma.EventError.NotOpen, kalymma.events.subscribe(on_wake, null));
}

test "opening twice is reported rather than silently accepted" {
    try open();
    defer kalymma.runtime.close();

    try testing.expect(kalymma.runtime.is_open());

    try testing.expectError(
        kalymma.RuntimeError.AlreadyOpen,
        kalymma.runtime.open(.{ .name = "x" }),
    );
}

test "an unnamed runtime is refused" {
    state.reset();

    try testing.expectError(kalymma.RuntimeError.Failed, kalymma.runtime.open(.{ .name = "" }));
    try testing.expect(!kalymma.runtime.is_open());
}

test "closing an unopened runtime is inert" {
    state.reset();

    kalymma.runtime.close();

    try testing.expect(!kalymma.runtime.is_open());
}

test "a created surface starts hidden and owns a frame of its own size" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    try testing.expect(handle.is_valid());
    try testing.expect(!kalymma.surface.is_visible(handle));
    try testing.expectEqual(@as(usize, 380 * 220), kalymma.surface.frame(handle).len);
    try testing.expectEqual(@as(u32, 1), kalymma.surface.scale(handle));
}

test "showing and hiding a surface flips its visibility" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    try kalymma.surface.show(handle);

    try testing.expect(kalymma.surface.is_visible(handle));

    kalymma.surface.hide(handle);

    try testing.expect(!kalymma.surface.is_visible(handle));
}

test "a destroyed surface is gone from every accessor" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();

    kalymma.surface.destroy(handle);

    try testing.expect(!kalymma.surface.is_visible(handle));
    try testing.expectEqual(@as(usize, 0), kalymma.surface.frame(handle).len);
    try testing.expectError(kalymma.SurfaceError.NotFound, kalymma.surface.show(handle));
    try testing.expectError(kalymma.SurfaceError.NotFound, kalymma.surface.present(handle));
}

test "the surface table fills to its bound and then reports the overflow" {
    try open();
    defer kalymma.runtime.close();

    var index: u32 = 0;

    while (index < kalymma.surfaces_max) : (index += 1) {
        _ = try surface_of();
    }

    try testing.expectError(kalymma.SurfaceError.TooMany, kalymma.surface.create(widget));
}

test "a configuration outside the contract bounds never reaches the backend" {
    try open();
    defer kalymma.runtime.close();

    const oversized = SurfaceConfig{
        .height = 220,
        .name = "widget",
        .width = kalymma.width_max + 1,
    };

    try testing.expectError(kalymma.SurfaceError.Invalid, kalymma.surface.create(oversized));
}

test "presenting records the call and leaves the frame in place" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    const pixels = kalymma.surface.frame(handle);

    pixels[0] = 0xFF102030;

    try kalymma.surface.present(handle);
    try kalymma.surface.present(handle);

    try testing.expectEqual(@as(u32, 2), state.count_of(.present));
    try testing.expectEqual(@as(u32, 0xFF102030), kalymma.surface.frame(handle)[0]);
}

test "a scripted failure surfaces as an error at the seam" {
    try open();
    defer kalymma.runtime.close();

    state.fail(.create);

    try testing.expectError(kalymma.SurfaceError.Failed, kalymma.surface.create(widget));

    state.clear_failure();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    state.fail(.show);

    try testing.expectError(kalymma.SurfaceError.Failed, kalymma.surface.show(handle));
}

test "a subscriber starts, reports itself, and stops" {
    try open();
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
    try open();

    const handle = try surface_of();

    try kalymma.events.subscribe(on_wake, null);

    kalymma.runtime.close();

    try testing.expect(!kalymma.events.is_subscribed());
    try testing.expectEqual(@as(usize, 0), kalymma.surface.frame(handle).len);
}

test "an injected event wakes the subscriber and drains on the app thread" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    try kalymma.events.subscribe(on_wake, null);

    state.inject(handle, .{ .pointer_move = .{ .x = 12, .y = 34 } });
    state.inject(handle, .{ .key_down = .escape });
    state.inject(handle, .{ .focus_lost = {} });

    try testing.expectEqual(@as(u32, 3), wakes);

    var list = EventList.init();

    try testing.expectEqual(@as(u32, 3), kalymma.events.poll(&list));
    try testing.expectEqual(kalymma.InputKind.pointer_move, kind_of(list.items[0]));
    try testing.expectEqual(@as(i32, 12), list.items[0].input.pointer_move.x);
    try testing.expectEqual(kalymma.Key.escape, list.items[1].input.key_down);
    try testing.expectEqual(kalymma.InputKind.focus_lost, kind_of(list.items[2]));
    try testing.expect(list.items[0].handle.eql(handle));

    try testing.expectEqual(@as(u32, 0), kalymma.events.poll(&list));
}

test "an overflowing queue drops the oldest events and counts the loss" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    var index: u32 = 0;

    while (index < kalymma.events_max + 2) : (index += 1) {
        state.inject(handle, .{ .pointer_move = .{ .x = @intCast(index), .y = 0 } });
    }

    var list = EventList.init();

    try testing.expectEqual(@as(u32, 2), kalymma.events.drops());
    try testing.expectEqual(kalymma.events_max, kalymma.events.poll(&list));
    try testing.expectEqual(@as(i32, 2), list.items[0].input.pointer_move.x);
}

test "an unsubscribed queue still collects events for the next drain" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    state.inject(handle, .{ .pointer_leave = {} });

    var list = EventList.init();

    try testing.expectEqual(@as(u32, 0), wakes);
    try testing.expectEqual(@as(u32, 1), kalymma.events.poll(&list));
}

test "the mock records every call the application makes" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();

    try kalymma.surface.show(handle);

    kalymma.surface.hide(handle);
    kalymma.surface.destroy(handle);

    try testing.expectEqual(@as(u32, 1), state.count_of(.open));
    try testing.expectEqual(@as(u32, 1), state.count_of(.create));
    try testing.expectEqual(@as(u32, 1), state.count_of(.show));
    try testing.expectEqual(@as(u32, 1), state.count_of(.hide));
    try testing.expectEqual(@as(u32, 1), state.count_of(.destroy));
}

test "a frame checksum tracks what the renderer wrote" {
    try open();
    defer kalymma.runtime.close();

    const handle = try surface_of();
    defer kalymma.surface.destroy(handle);

    const before = state.checksum(handle);

    const pixels = kalymma.surface.frame(handle);

    @memset(pixels, 0xFF1A1A1A);

    try testing.expect(state.checksum(handle) != before);
}
