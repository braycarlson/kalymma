const std = @import("std");

const kalymma = @import("root.zig");

const Event = kalymma.Event;
const FakeRuntime = kalymma.RuntimeType(kalymma.Fake);
const Surface = kalymma.Surface;
const testing = std.testing;

const widget = Surface.Options{
    .anchor = .bottom_right,
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

test {
    _ = @import("root.zig");
    _ = @import("runtime.zig");
}

const Waker = struct {
    wakes: u32 = 0,

    fn on_wake(waker: *Waker) void {
        waker.wakes += 1;
    }
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

fn surface_of(runtime: *FakeRuntime) !Surface {
    return try runtime.surface_create(widget);
}

test "a created surface starts hidden and owns a frame of its own size" {
    const runtime = try open();
    defer close(runtime);

    const surface = try surface_of(runtime);
    defer runtime.surface_destroy(surface);

    try testing.expect(!runtime.surface_is_visible(surface));
    try testing.expectEqual(@as(usize, 380 * 220), runtime.surface_frame(surface).len);
}

test "presenting records the call and leaves the frame in place" {
    const runtime = try open();
    defer close(runtime);

    const surface = try surface_of(runtime);
    defer runtime.surface_destroy(surface);

    runtime.surface_frame(surface)[0] = 0xFF102030;

    try runtime.surface_present(surface);
    try runtime.surface_present(surface);

    try testing.expectEqual(@as(u32, 2), runtime.platform.count_of(.surface_present));
    try testing.expectEqual(@as(u32, 0xFF102030), runtime.surface_frame(surface)[0]);
}

test "a scripted failure surfaces as an error at the seam" {
    const runtime = try open();
    defer close(runtime);

    runtime.platform.fault.arm(.surface_create);

    try testing.expectError(error.SurfaceCreateFailed, runtime.surface_create(widget));

    runtime.platform.fault.disarm();

    const surface = try surface_of(runtime);
    defer runtime.surface_destroy(surface);

    runtime.platform.fault.arm(.surface_show);

    try testing.expectError(error.SurfaceShowFailed, runtime.surface_show(surface));
}

test "an injected event wakes the subscriber and drains on the app thread" {
    const runtime = try open();
    defer close(runtime);

    const surface = try surface_of(runtime);
    defer runtime.surface_destroy(surface);

    var waker = Waker{};

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);

    runtime.platform.inject(surface, .{ .pointer_move = .{ .x = 12, .y = 34 } });
    runtime.platform.inject(surface, .{ .key_down = .escape });
    runtime.platform.inject(surface, .{ .focus_lost = {} });

    try testing.expectEqual(@as(u32, 3), waker.wakes);

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 3), runtime.events_poll(&list));

    const events = list.slice();

    try testing.expectEqual(Event.Input.Kind.pointer_move, std.meta.activeTag(events[0].input));
    try testing.expectEqual(kalymma.Key.escape, events[1].input.key_down);
    try testing.expectEqual(Event.Input.Kind.focus_lost, std.meta.activeTag(events[2].input));
    try testing.expectEqual(surface, events[0].source.surface);
}

test "the fake records every call the application makes" {
    const runtime = try open();
    defer close(runtime);

    const surface = try surface_of(runtime);

    try runtime.surface_show(surface);

    runtime.surface_hide(surface);
    runtime.surface_destroy(surface);

    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.init));
    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.surface_create));
    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.surface_show));
    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.surface_hide));
    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.surface_destroy));
}

test "a frame checksum tracks what the renderer wrote" {
    const runtime = try open();
    defer close(runtime);

    const surface = try surface_of(runtime);
    defer runtime.surface_destroy(surface);

    const before = runtime.platform.checksum(surface);

    @memset(runtime.surface_frame(surface), 0xFF1A1A1A);

    try testing.expect(runtime.platform.checksum(surface) != before);
}

const left_monitor = kalymma.Rect{ .height = 1080, .width = 1920, .x = 0, .y = 0 };
const right_monitor = kalymma.Rect{ .height = 1440, .width = 2560, .x = 1920, .y = 0 };

test "a shade event names the shade it came from" {
    const runtime = try open();
    defer close(runtime);

    const shade = try runtime.shade_create(.{
        .color = 0x80000000,
        .interactive = true,
        .rect = left_monitor,
    });

    defer runtime.shade_destroy(shade);

    var waker = Waker{};

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);

    runtime.platform.inject_shade(shade, .{ .pointer_down = .{ .x = 40, .y = 50 } });
    runtime.platform.inject_shade(shade, .{ .pointer_up = .{ .x = 400, .y = 300 } });

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 2), waker.wakes);
    try testing.expectEqual(@as(u32, 2), runtime.events_poll(&list));
    try testing.expectEqual(shade, list.slice()[0].source.shade);
    try testing.expectEqual(@as(i32, 400), list.slice()[1].input.pointer_up.x);
    try testing.expect(runtime.platform.shade_of(shade).?.interactive);
}

test "a monitor change reaches the application as a display event" {
    const runtime = try open();
    defer close(runtime);

    var waker = Waker{};
    var changed = kalymma.Monitor.List.init();

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);

    changed.append(kalymma.Monitor.init("DP-4", left_monitor));
    changed.append(kalymma.Monitor.init("DP-5", right_monitor));

    runtime.platform.set_monitors(&changed);

    var list = Event.List.init();
    var found = kalymma.Monitor.List.init();

    try testing.expectEqual(@as(u32, 1), waker.wakes);
    try testing.expectEqual(@as(u32, 1), runtime.events_poll(&list));
    try testing.expect(list.slice()[0].source == .display);
    try testing.expect(list.slice()[0].input == .monitors_changed);
    try testing.expectEqual(@as(u32, 2), runtime.monitors_list(&found));
    try testing.expect(found.eql(&changed));
}

test "a runtime opened again after deinit holds none of the shades it had" {
    const runtime = try open();
    defer close(runtime);

    const first = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });
    const second = try runtime.shade_create(.{ .color = 0x80000000, .rect = right_monitor });

    try testing.expectEqual(@as(u32, 2), runtime.platform.shade_table.count());

    runtime.deinit();

    try runtime.init(.{});

    try testing.expectEqual(@as(u32, 0), runtime.platform.shade_table.count());
    try testing.expect(runtime.platform.shade_of(first) == null);
    try testing.expect(runtime.platform.shade_of(second) == null);
}

test "a failed shade request surfaces as a platform error and changes nothing" {
    const runtime = try open();
    defer close(runtime);

    runtime.platform.fault.arm(.shade_create);

    try testing.expectError(
        error.ShadeCreateFailed,
        runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor }),
    );

    try testing.expectEqual(@as(u32, 0), runtime.platform.shade_table.count());

    runtime.platform.fault.disarm();

    const shade = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });
    defer runtime.shade_destroy(shade);

    runtime.platform.fault.arm(.shade_fill);

    try testing.expectError(error.ShadeUpdateFailed, runtime.shade_fill(shade, 0x40000000));
    try testing.expectEqual(@as(u32, 0x80000000), runtime.platform.shade_of(shade).?.color);

    runtime.platform.fault.arm(.shade_place);

    try testing.expectError(error.ShadeUpdateFailed, runtime.shade_place(shade, right_monitor));
    try testing.expect(std.meta.eql(left_monitor, runtime.platform.shade_of(shade).?.rect));
}

test "shades run out at the limit and come back once destroyed" {
    const runtime = try open();
    defer close(runtime);

    var shades: [kalymma.limits.shade_count_max]kalymma.Shade = undefined;

    for (&shades) |*shade| {
        shade.* = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });
    }

    try testing.expectError(
        error.ShadesExhausted,
        runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor }),
    );

    runtime.shade_destroy(shades[3]);

    const reused = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });

    try testing.expect(reused != shades[3]);
    try testing.expectError(error.ShadeUnknown, runtime.shade_fill(shades[3], 0));
}
