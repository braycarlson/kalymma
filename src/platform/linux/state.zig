const std = @import("std");

const contract = @import("../contract.zig");
const event_module = @import("../../event.zig");
const surface_module = @import("../../surface.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Event = event_module.Event;
const FrameStore = contract.FrameStore;
const Listener = contract.Listener;
const Options = surface_module.Options;
const Queue = event_module.Queue;
const Slot = contract.Slot;
const Surface = surface_module.Surface;
const Table = contract.Table;

pub const request_yield_max: u32 = 1 << 24;

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
};

pub const Pending = struct {
    index: u16,
    kind: Request,
};

comptime {
    assert(request_yield_max > 1);
}

var control: sys.Mutex = .{};
var done: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
var frames: FrameStore = .{};
var mutex: sys.Mutex = .{};
var pending: Request = .none;
var pending_index: u16 = 0;
var pending_ok: bool = false;
var queue: Queue = .{};
var ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(Status.idle));
var subscriber: ?Listener = null;
var subscriber_context: ?*anyopaque = null;
var table: Table = .{};
var thread: ?std.Thread = null;
var wake_fd: sys.Fd = -1;

pub fn current() Status {
    const result: Status = @fromBackingInt(status.load(.seq_cst));
    return result;
}

pub fn set_status(value: Status) void {
    status.store(@backingInt(value), .seq_cst);
}

pub fn is_open() bool {
    return current() == .running;
}

pub fn get_thread() ?std.Thread {
    return thread;
}

pub fn set_thread(value: ?std.Thread) void {
    thread = value;
}

pub fn set_wake(fd: sys.Fd) void {
    wake_fd = fd;
}

pub fn submit(kind: Request, index: u16) bool {
    assert(kind != .none);

    control.lock();

    pending = kind;
    pending_index = index;
    pending_ok = false;

    done.store(0, .seq_cst);
    ready.store(1, .seq_cst);

    control.unlock();

    sys.signal(wake_fd);

    var attempts: u32 = 0;

    while (attempts < request_yield_max) : (attempts += 1) {
        assert(attempts < request_yield_max);

        if (done.load(.seq_cst) == 1) {
            break;
        }

        std.Thread.yield() catch continue;
    }

    if (done.load(.seq_cst) != 1) {
        abandon();

        return false;
    }

    control.lock();
    defer control.unlock();

    return pending_ok;
}

pub fn take() ?Pending {
    if (ready.load(.seq_cst) == 0) {
        return null;
    }

    control.lock();
    defer control.unlock();

    if (pending == .none) {
        return null;
    }

    return .{ .index = pending_index, .kind = pending };
}

pub fn complete(succeeded: bool) void {
    control.lock();

    pending = .none;
    pending_ok = succeeded;

    ready.store(0, .seq_cst);

    control.unlock();

    done.store(1, .seq_cst);
}

pub fn abandon() void {
    control.lock();

    pending = .none;
    pending_ok = false;

    ready.store(0, .seq_cst);

    control.unlock();

    done.store(1, .seq_cst);
}

pub fn acquire(options: *const Options) CapacityError!Surface {
    mutex.lock();
    defer mutex.unlock();

    const surface = try table.acquire(options);

    frames.clear(surface_module.unpack(surface).index);

    return surface;
}

pub fn release(surface: Surface) void {
    mutex.lock();
    defer mutex.unlock();

    if (table.resolve(surface) == null) {
        return;
    }

    frames.clear(surface_module.unpack(surface).index);
    table.release(surface);
}

pub fn resolve(surface: Surface) ?*Slot {
    return table.resolve(surface);
}

pub fn slot_at(index: u16) *Slot {
    assert(index < surface_module.surface_count_max);

    return &table.slots[index];
}

pub fn clear_surfaces() void {
    mutex.lock();
    defer mutex.unlock();

    table.clear();
}

pub fn frame_of(surface: Surface) []u32 {
    mutex.lock();
    defer mutex.unlock();

    const slot = table.resolve(surface) orelse return &.{};
    return frames.view(surface_module.unpack(surface).index, slot);
}

pub fn frame_at(index: u16) []const u32 {
    assert(index < surface_module.surface_count_max);

    mutex.lock();
    defer mutex.unlock();

    const slot = &table.slots[index];

    if (!slot.used) {
        return &.{};
    }

    return frames.view(index, slot);
}

pub fn set_subscriber(listener: ?Listener, context: ?*anyopaque) void {
    mutex.lock();
    defer mutex.unlock();

    subscriber = listener;
    subscriber_context = context;
}

pub fn is_subscribed() bool {
    mutex.lock();
    defer mutex.unlock();

    return subscriber != null;
}

pub fn publish(index: u16, input: Event.Input) void {
    assert(index < surface_module.surface_count_max);

    mutex.lock();

    const slot = &table.slots[index];

    if (!slot.used) {
        mutex.unlock();

        return;
    }

    const surface = surface_module.pack(index, slot.generation);

    queue.push(.{ .input = input, .surface = surface });

    const listener = subscriber;
    const context = subscriber_context;

    mutex.unlock();

    if (listener) |wake| {
        if (context) |owner| {
            wake(owner);
        }
    }
}

pub fn drain(list: *Event.List) u32 {
    mutex.lock();
    defer mutex.unlock();

    return queue.drain(list);
}

pub fn clear_events() void {
    mutex.lock();
    defer mutex.unlock();

    queue.clear();

    subscriber = null;
    subscriber_context = null;
}
