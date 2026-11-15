const std = @import("std");

const kalymma = @import("kalymma");

const assert = std.debug.assert;

const Event = kalymma.Event;

const rounds_max: u32 = 1 << 16;

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

pub fn main(init: std.process.Init) !void {
    var runtime: kalymma.Runtime = undefined;

    try runtime.init(.{});
    defer runtime.deinit();

    const options = kalymma.Surface.Options{
        .anchor = .top_right,
        .height = 64,
        .margin = 16,
        .name = "status",
        .width = 256,
    };

    const status = try runtime.surface_create(options);
    defer runtime.surface_destroy(status);

    var waker = Waker{ .io = init.io };

    runtime.events_subscribe(Waker, &waker, Waker.on_wake);
    defer runtime.events_unsubscribe();

    @memset(runtime.surface_frame(status), 0xFF102030);

    try runtime.surface_show(status);
    try runtime.surface_present(status);

    assert(runtime.surface_is_visible(status));

    var list = Event.List.init();
    var rounds: u32 = 0;

    while (rounds < rounds_max) : (rounds += 1) {
        if (!waker.wait()) return;

        _ = runtime.events_poll(&list);

        for (list.slice()) |event| {
            if (event.input == .key_down) {
                runtime.surface_hide(status);

                return;
            }
        }
    }
}
