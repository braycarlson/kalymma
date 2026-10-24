const std = @import("std");

const kalymma = @import("root.zig");

const Event = kalymma.Event;
const Surface = kalymma.Surface;
const state = kalymma.mock.state;
const testing = std.testing;

const widget = kalymma.surface.Options{
    .anchor = .bottom_right,
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

test {
    _ = @import("events.zig");
    _ = @import("platform/mock/events.zig");
    _ = @import("platform/mock/runtime.zig");
    _ = @import("platform/mock/surface.zig");
    _ = @import("root.zig");
    _ = @import("runtime.zig");
}

const Waker = struct {
    wakes: u32 = 0,

    fn on_wake(waker: *Waker) void {
        waker.wakes += 1;
    }
};

fn open() !void {
    state.reset();

    try kalymma.runtime.open();
}

fn surface_of() !Surface {
    return try kalymma.surface.create(widget);
}

test "a created surface starts hidden and owns a frame of its own size" {
    try open();
    defer kalymma.runtime.close();

    const surface = try surface_of();
    defer kalymma.surface.destroy(surface);

    try testing.expect(!kalymma.surface.is_visible(surface));
    try testing.expectEqual(@as(usize, 380 * 220), kalymma.surface.frame(surface).len);
}

test "presenting records the call and leaves the frame in place" {
    try open();
    defer kalymma.runtime.close();

    const surface = try surface_of();
    defer kalymma.surface.destroy(surface);

    kalymma.surface.frame(surface)[0] = 0xFF102030;

    try kalymma.surface.present(surface);
    try kalymma.surface.present(surface);

    try testing.expectEqual(@as(u32, 2), state.count_of(.present));
    try testing.expectEqual(@as(u32, 0xFF102030), kalymma.surface.frame(surface)[0]);
}

test "a scripted failure surfaces as an error at the seam" {
    try open();
    defer kalymma.runtime.close();

    state.fail(.create);

    try testing.expectError(error.SurfaceCreateFailed, kalymma.surface.create(widget));

    state.clear_failure();

    const surface = try surface_of();
    defer kalymma.surface.destroy(surface);

    state.fail(.show);

    try testing.expectError(error.SurfaceShowFailed, kalymma.surface.show(surface));
}

test "an injected event wakes the subscriber and drains on the app thread" {
    try open();
    defer kalymma.runtime.close();

    const surface = try surface_of();
    defer kalymma.surface.destroy(surface);

    var waker = Waker{};

    kalymma.events.subscribe(Waker, &waker, Waker.on_wake);

    state.inject(surface, .{ .pointer_move = .{ .x = 12, .y = 34 } });
    state.inject(surface, .{ .key_down = .escape });
    state.inject(surface, .{ .focus_lost = {} });

    try testing.expectEqual(@as(u32, 3), waker.wakes);

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 3), kalymma.events.poll(&list));

    const events = list.slice();

    try testing.expectEqual(Event.Input.Kind.pointer_move, std.meta.activeTag(events[0].input));
    try testing.expectEqual(kalymma.Key.escape, events[1].input.key_down);
    try testing.expectEqual(Event.Input.Kind.focus_lost, std.meta.activeTag(events[2].input));
    try testing.expectEqual(surface, events[0].surface);
}

test "the mock records every call the application makes" {
    try open();
    defer kalymma.runtime.close();

    const surface = try surface_of();

    try kalymma.surface.show(surface);

    kalymma.surface.hide(surface);
    kalymma.surface.destroy(surface);

    try testing.expectEqual(@as(u32, 1), state.count_of(.open));
    try testing.expectEqual(@as(u32, 1), state.count_of(.create));
    try testing.expectEqual(@as(u32, 1), state.count_of(.show));
    try testing.expectEqual(@as(u32, 1), state.count_of(.hide));
    try testing.expectEqual(@as(u32, 1), state.count_of(.destroy));
}

test "a frame checksum tracks what the renderer wrote" {
    try open();
    defer kalymma.runtime.close();

    const surface = try surface_of();
    defer kalymma.surface.destroy(surface);

    const before = state.checksum(surface);

    @memset(kalymma.surface.frame(surface), 0xFF1A1A1A);

    try testing.expect(state.checksum(surface) != before);
}
