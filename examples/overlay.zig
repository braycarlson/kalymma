const std = @import("std");

const kalymma = @import("kalymma");

const assert = std.debug.assert;

const Event = kalymma.Event;

const attempts_max: u32 = 1 << 24;

const Waker = struct {
    wakes: std.atomic.Value(u32) = .init(0),

    fn on_wake(waker: *Waker) void {
        _ = waker.wakes.fetchAdd(1, .seq_cst);
    }
};

pub fn main() !void {
    try kalymma.runtime.open();
    defer kalymma.runtime.close();

    assert(kalymma.runtime.is_open());

    const options = kalymma.surface.Options{
        .anchor = .top_right,
        .height = 64,
        .margin = 16,
        .name = "status",
        .width = 256,
    };

    const status = try kalymma.surface.create(options);
    defer kalymma.surface.destroy(status);

    var waker = Waker{};

    kalymma.events.subscribe(Waker, &waker, Waker.on_wake);
    defer kalymma.events.unsubscribe();

    @memset(kalymma.surface.frame(status), 0xFF102030);

    try kalymma.surface.show(status);
    try kalymma.surface.present(status);

    assert(kalymma.surface.is_visible(status));

    var list = Event.List.init();
    var attempts: u32 = 0;

    while (attempts < attempts_max) : (attempts += 1) {
        if (waker.wakes.load(.seq_cst) == 0) {
            std.Thread.yield() catch continue;

            continue;
        }

        waker.wakes.store(0, .seq_cst);

        _ = kalymma.events.poll(&list);

        for (list.slice()) |event| {
            if (event.input == .key_down) {
                kalymma.surface.hide(status);

                return;
            }
        }
    }
}
