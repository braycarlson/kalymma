const std = @import("std");

const contract = @import("../contract.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const EventCallback = contract.EventCallback;
const EventList = contract.EventList;
const EventQueue = contract.EventQueue;
const FrameStore = contract.FrameStore;
const Handle = contract.Handle;
const InputEvent = contract.InputEvent;
const Slot = contract.Slot;
const SurfaceConfig = contract.SurfaceConfig;
const SurfaceTable = contract.SurfaceTable;

pub const surfaces_max: u32 = contract.surfaces_max;

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
var queue: EventQueue = .{};
var ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Status.idle));
var subscriber: ?EventCallback = null;
var subscriber_context: ?*anyopaque = null;
var table: SurfaceTable = .{};
var thread: ?std.Thread = null;
var wake_fd: sys.Fd = -1;

pub fn current() Status {
    const result: Status = @enumFromInt(status.load(.seq_cst));

    return result;
}

pub fn set_status(value: Status) void {
    status.store(@intFromEnum(value), .seq_cst);
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

pub fn acquire(config: *const SurfaceConfig) contract.SurfaceError!Handle {
    mutex.lock();
    defer mutex.unlock();

    const handle = try table.acquire(config);

    frames.clear(handle.index);

    return handle;
}

pub fn release(handle: Handle) void {
    mutex.lock();
    defer mutex.unlock();

    if (table.resolve(handle) == null) {
        return;
    }

    frames.clear(handle.index);
    table.release(handle);
}

pub fn resolve(handle: Handle) ?*Slot {
    return table.resolve(handle);
}

pub fn slot_at(index: u16) *Slot {
    assert(index < surfaces_max);

    return &table.slots[index];
}

pub fn clear_surfaces() void {
    mutex.lock();
    defer mutex.unlock();

    table.clear();
}

pub fn frame_of(handle: Handle) []u32 {
    mutex.lock();
    defer mutex.unlock();

    const slot = table.resolve(handle) orelse return &.{};

    return frames.view(handle.index, slot);
}

pub fn frame_at(index: u16) []const u32 {
    assert(index < surfaces_max);

    mutex.lock();
    defer mutex.unlock();

    const slot = &table.slots[index];

    if (!slot.used) {
        return &.{};
    }

    return frames.view(index, slot);
}

pub fn set_subscriber(callback: ?EventCallback, context: ?*anyopaque) void {
    mutex.lock();
    defer mutex.unlock();

    subscriber = callback;
    subscriber_context = context;
}

pub fn is_subscribed() bool {
    mutex.lock();
    defer mutex.unlock();

    return subscriber != null;
}

pub fn publish(index: u16, input: InputEvent) void {
    assert(index < surfaces_max);

    mutex.lock();

    const slot = &table.slots[index];

    if (!slot.used) {
        mutex.unlock();

        return;
    }

    const handle = Handle{ .generation = slot.generation, .index = index };

    queue.push(.{ .handle = handle, .input = input });

    const callback = subscriber;
    const context = subscriber_context;

    mutex.unlock();

    if (callback) |present| {
        present(context);
    }
}

pub fn drain(list: *EventList) u32 {
    mutex.lock();
    defer mutex.unlock();

    return queue.drain(list);
}

pub fn drops() u32 {
    mutex.lock();
    defer mutex.unlock();

    return queue.drops;
}

pub fn clear_events() void {
    mutex.lock();
    defer mutex.unlock();

    queue.clear();

    subscriber = null;
    subscriber_context = null;
}
