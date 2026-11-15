const std = @import("std");

const kalymma = @import("kalymma");

const assert = std.debug.assert;

const Event = kalymma.Event;
const Point = kalymma.Point;
const Rect = kalymma.Rect;
const Shade = kalymma.Shade;

const dim: u32 = 0x99000000;
const rounds_max: u32 = 1 << 16;
const tint: u32 = 0x26000000;

const idle_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(60) },
};

const Waker = struct {
    event: std.Io.Event = .unset,
    io: std.Io,

    fn on_wake(waker: *Waker) void {
        waker.event.set(waker.io);
    }

    fn wait(waker: *Waker) bool {
        waker.event.waitTimeout(waker.io, idle_timeout) catch return false;
        waker.event.reset();

        return true;
    }
};

const Drawing = struct {
    anchor: ?Point = null,
    region: ?Shade = null,
    runtime: *kalymma.Runtime,
    screen: Rect,

    fn follow(drawing: *Drawing, input: Event.Input) !bool {
        switch (input) {
            .key_down => |key| return key != .escape,
            .pointer_down => |point| drawing.anchor = point,
            .pointer_move => |point| try drawing.stretch(point),
            .pointer_up => drawing.anchor = null,
            .pointer_leave, .focus_lost, .monitors_changed => {},
        }

        return true;
    }

    fn stretch(drawing: *Drawing, point: Point) !void {
        const anchor = drawing.anchor orelse return;
        const rect = span(drawing.screen, anchor, point);

        if (drawing.region) |region| {
            try drawing.runtime.shade_place(region, rect);

            return;
        }

        drawing.region = try drawing.runtime.shade_create(.{ .color = dim, .rect = rect });
    }
};

pub fn main(init: std.process.Init) !void {
    var runtime: kalymma.Runtime = undefined;

    try runtime.init(.{});
    defer runtime.deinit();

    var monitors = kalymma.Monitor.List.init();

    if (runtime.monitors_list(&monitors) == 0) {
        return error.NoMonitor;
    }

    const screen = monitors.slice()[0].rect;

    const canvas = try runtime.shade_create(.{
        .color = tint,
        .interactive = true,
        .rect = screen,
    });

    defer runtime.shade_destroy(canvas);

    var waker = Waker{ .io = init.io };

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);
    defer runtime.events_unsubscribe();

    var drawing = Drawing{ .runtime = &runtime, .screen = screen };
    var list = Event.List.init();
    var rounds: u32 = 0;

    while (rounds < rounds_max) : (rounds += 1) {
        if (!waker.wait()) return;

        _ = runtime.events_poll(&list);

        for (list.slice()) |event| {
            if (event.source != .shade) continue;
            if (!try drawing.follow(event.input)) return;
        }
    }
}

fn span(screen: Rect, start: Point, end: Point) Rect {
    const left = @min(start.x, end.x);
    const top = @min(start.y, end.y);

    const result = Rect{
        .height = @max(@max(start.y, end.y) - top, 1),
        .width = @max(@max(start.x, end.x) - left, 1),
        .x = screen.x + left,
        .y = screen.y + top,
    };

    assert(!result.is_empty());

    return result;
}
