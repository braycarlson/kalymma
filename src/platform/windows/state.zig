const std = @import("std");

const contract = @import("../contract.zig");
const win32 = @import("win32.zig");

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

pub const Status = enum(u8) {
    idle = 0,
    starting = 1,
    running = 2,
    failed = 3,
};

pub const Mutex = struct {
    lock_state: win32.SRWLOCK = .{},

    pub fn lock(mutex: *Mutex) void {
        win32.AcquireSRWLockExclusive(&mutex.lock_state);
    }

    pub fn unlock(mutex: *Mutex) void {
        win32.ReleaseSRWLockExclusive(&mutex.lock_state);
    }

    pub fn try_lock(mutex: *Mutex) bool {
        return win32.TryAcquireSRWLockExclusive(&mutex.lock_state) != 0;
    }
};

pub const Window = struct {
    bits: ?[*]u32 = null,
    dib: ?win32.HBITMAP = null,
    handle: ?win32.HWND = null,
    memory: ?win32.HDC = null,
    tracking: bool = false,
};

var controller: ?win32.HWND = null;
var frames: FrameStore = .{};
var guard: Mutex = .{};
var queue: EventQueue = .{};
var status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Status.idle));
var subscriber: ?EventCallback = null;
var subscriber_context: ?*anyopaque = null;
var table: SurfaceTable = .{};
var thread: ?std.Thread = null;
var windows: [surfaces_max]Window = @splat(.{});

pub fn lock() void {
    guard.lock();
}

pub fn unlock() void {
    guard.unlock();
}

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

pub fn get_controller() ?win32.HWND {
    return controller;
}

pub fn set_controller(value: ?win32.HWND) void {
    controller = value;
}

pub fn window_at(index: u16) *Window {
    assert(index < surfaces_max);

    return &windows[index];
}

pub fn acquire(config: *const SurfaceConfig) contract.SurfaceError!Handle {
    guard.lock();
    defer guard.unlock();

    const handle = try table.acquire(config);

    frames.clear(handle.index);

    windows[handle.index] = Window{};

    return handle;
}

pub fn release(handle: Handle) void {
    guard.lock();
    defer guard.unlock();

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
    guard.lock();
    defer guard.unlock();

    table.clear();

    windows = @splat(.{});
}

pub fn frame_of(handle: Handle) []u32 {
    guard.lock();
    defer guard.unlock();

    const slot = table.resolve(handle) orelse return &.{};

    return frames.view(handle.index, slot);
}

pub fn copy_frame(index: u16, destination: [*]u32) void {
    assert(index < surfaces_max);

    guard.lock();
    defer guard.unlock();

    const slot = &table.slots[index];

    if (!slot.used) {
        return;
    }

    const pixels = frames.view(index, slot);

    @memcpy(destination[0..pixels.len], pixels);
}

pub fn set_subscriber(callback: ?EventCallback, context: ?*anyopaque) void {
    guard.lock();
    defer guard.unlock();

    subscriber = callback;
    subscriber_context = context;
}

pub fn is_subscribed() bool {
    guard.lock();
    defer guard.unlock();

    return subscriber != null;
}

pub fn publish(index: u16, input: InputEvent) void {
    assert(index < surfaces_max);

    guard.lock();

    const slot = &table.slots[index];

    if (!slot.used) {
        guard.unlock();

        return;
    }

    const handle = Handle{ .generation = slot.generation, .index = index };

    queue.push(.{ .handle = handle, .input = input });

    const callback = subscriber;
    const context = subscriber_context;

    guard.unlock();

    if (callback) |present| {
        present(context);
    }
}

pub fn drain(list: *EventList) u32 {
    guard.lock();
    defer guard.unlock();

    return queue.drain(list);
}

pub fn drops() u32 {
    guard.lock();
    defer guard.unlock();

    return queue.drops;
}

pub fn clear_events() void {
    guard.lock();
    defer guard.unlock();

    queue.clear();

    subscriber = null;
    subscriber_context = null;
}
