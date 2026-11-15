const std = @import("std");

const event_module = @import("../../event.zig");
const geometry = @import("../geometry.zig");
const interface = @import("../interface.zig");
const monitor_module = @import("../../monitor.zig");
const shade_module = @import("../../shade.zig");
const surface_module = @import("../../surface.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const FrameStore = interface.FrameStore;
const Listener = interface.Listener;
const Monitor = monitor_module.Monitor;
const Options = Surface.Options;
const Queue = event_module.Queue;
const Rect = geometry.Rect;
const Shade = shade_module.Shade;
const ShadeCapacityError = shade_module.CapacityError;
const ShadeOptions = Shade.Options;
const ShadeRequest = interface.ShadeRequest;
const ShadeSlot = interface.ShadeSlot;
const ShadeTable = interface.ShadeTable;
const Slot = interface.Slot;
const State = @This();
const Surface = surface_module.Surface;
const Table = interface.Table;

control: sys.Mutex = .{},
done: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
frames: FrameStore = .{},
monitors: Monitor.List = .{ .count = 0, .items = @splat(.{}) },
mutex: sys.Mutex = .{},
pending: Request = .none,
pending_index: u16 = 0,
pending_ok: bool = false,
queue: Queue = .{},
ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
shade_table: ShadeTable = .{},
status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(Status.idle)),
subscriber: ?Listener = null,
subscriber_context: ?*anyopaque = null,
table: Table = .{},
thread: ?std.Thread = null,
wake_fd: sys.Fd = -1,

pub const Status = enum(u8) {
    idle = 0,
    starting = 1,
    running = 2,
    failed = 3,
};

pub const Request = enum(u8) {
    none = 0,
    create = 1,
    destroy = 2,
    show = 3,
    hide = 4,
    present = 5,
    stop = 6,
    shade_create = 7,
    shade_destroy = 8,
    shade_fill = 9,
    shade_place = 10,
    shade_cursor = 11,

    pub fn is_shade(kind: Request) bool {
        const result = switch (kind) {
            .shade_create, .shade_destroy, .shade_fill, .shade_place, .shade_cursor => true,
            .none, .create, .destroy, .show, .hide, .present, .stop => false,
        };

        return result;
    }

    pub fn index_count(kind: Request) u32 {
        const result = if (kind.is_shade())
            shade_module.count_max
        else
            surface_module.count_max;

        assert(result > 0);

        return result;
    }
};

pub const Pending = struct {
    index: u16,
    kind: Request,
};

pub const request_yield_max: u32 = 1 << 24;

comptime {
    assert(request_yield_max > 1);
}

pub fn current(state: *const State) Status {
    const result: Status = @fromBackingInt(state.status.load(.seq_cst));
    return result;
}

pub fn set_status(state: *State, value: Status) void {
    state.status.store(@backingInt(value), .seq_cst);
}

pub fn is_open(state: *const State) bool {
    return state.current() == .running;
}

pub fn get_thread(state: *const State) ?std.Thread {
    return state.thread;
}

pub fn set_thread(state: *State, value: ?std.Thread) void {
    if (value != null) assert(state.thread == null);
    if (value == null) assert(state.thread != null);

    state.thread = value;
}

pub fn set_wake(state: *State, fd: sys.Fd) void {
    state.control.lock();
    defer state.control.unlock();

    state.wake_fd = fd;
}

pub fn submit(state: *State, kind: Request, index: u16) bool {
    assert(kind != .none);
    assert(index < kind.index_count());

    state.control.lock();

    if (state.wake_fd < 0) {
        state.control.unlock();

        return false;
    }

    state.pending = kind;
    state.pending_index = index;
    state.pending_ok = false;

    state.done.store(0, .seq_cst);
    state.ready.store(1, .seq_cst);

    sys.signal(state.wake_fd);

    state.control.unlock();

    var attempts: u32 = 0;

    while (attempts < request_yield_max) : (attempts += 1) {
        assert(attempts < request_yield_max);

        if (state.done.load(.seq_cst) == 1) {
            break;
        }

        std.Thread.yield() catch continue;
    }

    if (state.done.load(.seq_cst) != 1) {
        state.abandon();

        return false;
    }

    state.control.lock();
    defer state.control.unlock();

    return state.pending_ok;
}

pub fn submit_shade(state: *State, request: ShadeRequest, index: u16) bool {
    assert(index < shade_module.count_max);

    const kind: Request = switch (request) {
        .create => .shade_create,
        .destroy => .shade_destroy,
        .fill => .shade_fill,
        .place => .shade_place,
        .cursor => .shade_cursor,
    };

    assert(kind.is_shade());

    return state.submit(kind, index);
}

pub fn take(state: *State) ?Pending {
    if (state.ready.load(.seq_cst) == 0) {
        return null;
    }

    state.control.lock();
    defer state.control.unlock();

    if (state.pending == .none) {
        return null;
    }

    return .{ .index = state.pending_index, .kind = state.pending };
}

pub fn complete(state: *State, succeeded: bool) void {
    state.control.lock();

    state.pending = .none;
    state.pending_ok = succeeded;

    state.ready.store(0, .seq_cst);

    state.control.unlock();

    state.done.store(1, .seq_cst);
}

pub fn abandon(state: *State) void {
    state.control.lock();

    state.pending = .none;
    state.pending_ok = false;

    state.ready.store(0, .seq_cst);

    state.control.unlock();

    state.done.store(1, .seq_cst);
}

pub fn acquire(state: *State, options: *const Options) CapacityError!Surface {
    state.mutex.lock();
    defer state.mutex.unlock();

    const surface = try state.table.acquire(options);

    state.frames.clear(surface_module.unpack(surface).index);

    return surface;
}

pub fn release(state: *State, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    if (state.table.resolve(surface) == null) {
        return;
    }

    state.frames.clear(surface_module.unpack(surface).index);
    state.table.release(surface);
}

pub fn resolve(state: *State, surface: Surface) ?*Slot {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return state.table.resolve(surface);
}

pub fn slot_at(state: *State, index: u16) *Slot {
    assert(index < surface_module.count_max);

    return &state.table.slots[index];
}

pub fn clear_surfaces(state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    state.table.clear();
}

pub fn frame_of(state: *State, surface: Surface) []u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    const slot = state.table.resolve(surface) orelse return &.{};
    return state.frames.view(surface_module.unpack(surface).index, slot);
}

pub fn frame_at(state: *State, index: u16) []const u32 {
    assert(index < surface_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    const slot = &state.table.slots[index];

    if (!slot.used) {
        return &.{};
    }

    return state.frames.view(index, slot);
}

pub fn set_subscriber(state: *State, listener: ?Listener, context: ?*anyopaque) void {
    if (listener != null) assert(context != null);
    if (listener == null) assert(context == null);

    state.mutex.lock();
    defer state.mutex.unlock();

    state.subscriber = listener;
    state.subscriber_context = context;
}

pub fn is_subscribed(state: *State) bool {
    state.mutex.lock();
    defer state.mutex.unlock();

    return state.subscriber != null;
}

pub fn publish(state: *State, index: u16, input: Event.Input) void {
    assert(index < surface_module.count_max);
    assert(input != .monitors_changed);

    state.mutex.lock();

    const slot = &state.table.slots[index];

    if (!slot.used) {
        state.mutex.unlock();

        return;
    }

    const surface = surface_module.pack(index, slot.generation);

    state.push_then_unlock(.{ .input = input, .source = .{ .surface = surface } });
}

pub fn publish_shade(state: *State, index: u16, input: Event.Input) void {
    assert(index < shade_module.count_max);
    assert(input != .monitors_changed);

    state.mutex.lock();

    const slot = &state.shade_table.slots[index];

    if (!slot.used) {
        state.mutex.unlock();

        return;
    }

    const shade = shade_module.pack(index, slot.generation);

    state.push_then_unlock(.{ .input = input, .source = .{ .shade = shade } });
}

fn push_then_unlock(state: *State, event: Event) void {
    state.queue.push(event);

    const listener = state.subscriber;
    const context = state.subscriber_context;

    state.mutex.unlock();

    if (listener) |wake| {
        if (context) |owner| {
            wake(owner);
        }
    }
}

pub fn set_monitors(state: *State, list: *const Monitor.List) void {
    assert(list.count <= monitor_module.count_max);

    state.mutex.lock();

    if (state.monitors.eql(list)) {
        state.mutex.unlock();

        return;
    }

    state.monitors = list.*;

    if (state.current() != .running) {
        state.mutex.unlock();

        return;
    }

    state.push_then_unlock(.{ .input = .{ .monitors_changed = {} }, .source = .{ .display = {} } });
}

pub fn copy_monitors(state: *State, target: *Monitor.List) u32 {
    state.mutex.lock();
    defer state.mutex.unlock();

    target.* = state.monitors;

    assert(target.count <= monitor_module.count_max);

    return target.count;
}

pub fn clear_monitors(state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    state.monitors.clear();
}

pub fn acquire_shade(state: *State, options: *const ShadeOptions) ShadeCapacityError!Shade {
    assert(options.is_valid());

    state.mutex.lock();
    defer state.mutex.unlock();

    return try state.shade_table.acquire(options);
}

pub fn release_shade(state: *State, shade: Shade) void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    state.shade_table.release(shade);
}

pub fn has_shade(state: *State, shade: Shade) bool {
    assert(shade_module.unpack(shade).generation > 0);

    state.mutex.lock();
    defer state.mutex.unlock();

    return state.shade_table.resolve(shade) != null;
}

pub fn recolor_shade(state: *State, shade: Shade, color: u32) ?u32 {
    assert(shade_module.unpack(shade).generation > 0);

    state.mutex.lock();
    defer state.mutex.unlock();

    return state.shade_table.recolor(shade, color);
}

pub fn move_shade(state: *State, shade: Shade, rect: Rect) ?Rect {
    assert(shade_module.unpack(shade).generation > 0);
    assert(!rect.is_empty());

    state.mutex.lock();
    defer state.mutex.unlock();

    return state.shade_table.move(shade, rect);
}

pub fn change_shade_cursor(state: *State, shade: Shade, cursor: Cursor) ?Cursor {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    return state.shade_table.change_cursor(shade, cursor);
}

pub fn shade_at(state: *State, index: u16) ShadeSlot {
    assert(index < shade_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    return state.shade_table.slots[index];
}

pub fn clear_shades(state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    state.shade_table.clear();
}

pub fn drain(state: *State, list: *Event.List) u32 {
    state.mutex.lock();
    defer state.mutex.unlock();

    return state.queue.drain(list);
}

pub fn clear_events(state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    state.queue.clear();

    state.subscriber = null;
    state.subscriber_context = null;
}

const testing = std.testing;

fn create() !*State {
    const state = try testing.allocator.create(State);

    state.* = .{};

    return state;
}

test "a request without a wake descriptor fails at once and leaves nothing pending" {
    const state = try create();
    defer testing.allocator.destroy(state);

    state.set_wake(-1);

    try testing.expect(!state.submit(.show, 0));
    try testing.expect(!state.submit(.shade_fill, shade_module.count_max - 1));
    try testing.expect(state.take() == null);
}

test "shade requests address the shade table and surface requests the surface table" {
    try testing.expectEqual(shade_module.count_max, Request.shade_place.index_count());
    try testing.expectEqual(surface_module.count_max, Request.present.index_count());
    try testing.expect(Request.shade_create.is_shade());
    try testing.expect(Request.shade_cursor.is_shade());
    try testing.expectEqual(shade_module.count_max, Request.shade_cursor.index_count());
    try testing.expect(!Request.stop.is_shade());
}

test "a monitor change is recorded but announced only while running" {
    const state = try create();
    defer testing.allocator.destroy(state);

    var list = Monitor.List.init();
    var copied = Monitor.List.init();
    var drained = Event.List.init();

    list.append(Monitor.init("DP-4", .{ .height = 1080, .width = 1920 }));

    state.set_status(.starting);
    state.set_monitors(&list);

    try testing.expectEqual(@as(u32, 1), state.copy_monitors(&copied));
    try testing.expectEqual(@as(u32, 0), state.drain(&drained));

    list.append(Monitor.init("DP-5", .{ .height = 1080, .width = 1920, .x = 1920 }));

    state.set_status(.running);
    state.set_monitors(&list);
    state.set_monitors(&list);
    state.set_status(.idle);

    try testing.expectEqual(@as(u32, 1), state.drain(&drained));
    try testing.expect(drained.slice()[0].source == .display);
    try testing.expectEqual(@as(u32, 2), state.copy_monitors(&copied));

    state.clear_monitors();
    state.clear_events();

    try testing.expectEqual(@as(u32, 0), state.copy_monitors(&copied));
}

test "a shade change reaches the slot the pump thread reads" {
    const state = try create();
    defer testing.allocator.destroy(state);

    const options = ShadeOptions{ .color = 0x80000000, .rect = .{ .height = 10, .width = 10 } };
    const shade = try state.acquire_shade(&options);
    const index = shade_module.unpack(shade).index;
    const moved = Rect{ .height = 20, .width = 30, .x = 5, .y = 6 };

    _ = state.recolor_shade(shade, 0x40000000);
    _ = state.move_shade(shade, moved);

    try testing.expectEqual(@as(u32, 0x40000000), state.shade_at(index).color);
    try testing.expect(std.meta.eql(moved, state.shade_at(index).rect));

    state.release_shade(shade);

    try testing.expect(!state.has_shade(shade));
    try testing.expect(!state.shade_at(index).used);
}
