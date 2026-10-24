const std = @import("std");

const event_module = @import("event.zig");
const platform = @import("platform.zig");
const runtime = @import("runtime.zig");
const surface_module = @import("surface.zig");

const assert = std.debug.assert;

const backend = platform.backend.events;

const Event = event_module.Event;

pub fn poll(list: *Event.List) u32 {
    const result = backend.poll(list);

    assert(result == list.count);
    assert(result <= event_module.event_count_max);

    return result;
}

pub fn subscribe(comptime Owner: type, owner: *Owner, comptime callback: fn (*Owner) void) void {
    assert(runtime.is_open());
    assert(!backend.is_subscribed());

    const Listener = ListenerType(Owner, callback);

    backend.subscribe(Listener.invoke, owner);

    assert(backend.is_subscribed());
}

pub fn unsubscribe() void {
    backend.unsubscribe();

    assert(!backend.is_subscribed());
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

const mock = platform.mock;

const Waker = struct {
    wakes: u32 = 0,

    fn on_wake(waker: *Waker) void {
        waker.wakes += 1;
    }
};

const widget = surface_module.Options{
    .height = 220,
    .margin = 12,
    .name = "widget",
    .width = 380,
};

test poll {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    mock.state.inject(surface, .{ .pointer_move = .{ .x = 12, .y = 34 } });
    mock.state.inject(surface, .{ .key_down = .escape });

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 2), poll(&list));
    try testing.expectEqual(@as(i32, 12), list.slice()[0].input.pointer_move.x);
    try testing.expectEqual(surface, list.slice()[1].surface);
    try testing.expectEqual(@as(u32, 0), poll(&list));
}

test subscribe {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    var waker = Waker{};

    subscribe(Waker, &waker, Waker.on_wake);

    mock.state.inject(surface, .{ .focus_lost = {} });

    try testing.expectEqual(@as(u32, 1), waker.wakes);
}

test unsubscribe {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    var waker = Waker{};

    subscribe(Waker, &waker, Waker.on_wake);
    unsubscribe();

    mock.state.inject(surface, .{ .pointer_leave = {} });

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 0), waker.wakes);
    try testing.expectEqual(@as(u32, 1), poll(&list));
}

test "closing the runtime drops the subscriber and every surface" {
    mock.state.reset();

    try runtime.open();

    const surface = try surface_module.create(widget);

    var waker = Waker{};

    subscribe(Waker, &waker, Waker.on_wake);

    runtime.close();

    try testing.expect(!backend.is_subscribed());
    try testing.expectEqual(@as(usize, 0), surface_module.frame(surface).len);
}

test "an overflowing queue keeps the newest events" {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const surface = try surface_module.create(widget);
    defer surface_module.destroy(surface);

    var index: u32 = 0;

    while (index < event_module.event_count_max + 2) : (index += 1) {
        mock.state.inject(surface, .{ .pointer_move = .{ .x = @intCast(index), .y = 0 } });
    }

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 2), mock.state.drops());
    try testing.expectEqual(event_module.event_count_max, poll(&list));
    try testing.expectEqual(@as(i32, 2), list.slice()[0].input.pointer_move.x);
}
