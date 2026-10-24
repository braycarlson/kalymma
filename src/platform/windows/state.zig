const std = @import("std");

const contract = @import("../contract.zig");
const event_module = @import("../../event.zig");
const surface_module = @import("../../surface.zig");
const win32 = @import("win32.zig");

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
var queue: Queue = .{};
var status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(Status.idle));
var subscriber: ?Listener = null;
var subscriber_context: ?*anyopaque = null;
var table: Table = .{};
var thread: ?std.Thread = null;
var windows: [surface_module.surface_count_max]Window = @splat(.{});

pub fn lock() void {
    guard.lock();
}

pub fn unlock() void {
    guard.unlock();
}

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

pub fn get_controller() ?win32.HWND {
    return controller;
}

pub fn set_controller(value: ?win32.HWND) void {
    controller = value;
}

pub fn window_at(index: u16) *Window {
    assert(index < surface_module.surface_count_max);

    return &windows[index];
}

pub fn acquire(options: *const Options) CapacityError!Surface {
    guard.lock();
    defer guard.unlock();

    const surface = try table.acquire(options);
    const index = surface_module.unpack(surface).index;

    frames.clear(index);

    windows[index] = Window{};

    return surface;
}

pub fn release(surface: Surface) void {
    guard.lock();
    defer guard.unlock();

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
    guard.lock();
    defer guard.unlock();

    table.clear();

    windows = @splat(.{});
}

pub fn frame_of(surface: Surface) []u32 {
    guard.lock();
    defer guard.unlock();

    const slot = table.resolve(surface) orelse return &.{};
    return frames.view(surface_module.unpack(surface).index, slot);
}

pub fn copy_frame(index: u16, destination: [*]u32) void {
    assert(index < surface_module.surface_count_max);

    guard.lock();
    defer guard.unlock();

    const slot = &table.slots[index];

    if (!slot.used) {
        return;
    }

    const pixels = frames.view(index, slot);

    @memcpy(destination[0..pixels.len], pixels);
}

pub fn set_subscriber(listener: ?Listener, context: ?*anyopaque) void {
    guard.lock();
    defer guard.unlock();

    subscriber = listener;
    subscriber_context = context;
}

pub fn is_subscribed() bool {
    guard.lock();
    defer guard.unlock();

    return subscriber != null;
}

pub fn publish(index: u16, input: Event.Input) void {
    assert(index < surface_module.surface_count_max);

    guard.lock();

    const slot = &table.slots[index];

    if (!slot.used) {
        guard.unlock();

        return;
    }

    const surface = surface_module.pack(index, slot.generation);

    queue.push(.{ .input = input, .surface = surface });

    const listener = subscriber;
    const context = subscriber_context;

    guard.unlock();

    if (listener) |wake| {
        if (context) |owner| {
            wake(owner);
        }
    }
}

pub fn drain(list: *Event.List) u32 {
    guard.lock();
    defer guard.unlock();

    return queue.drain(list);
}

pub fn clear_events() void {
    guard.lock();
    defer guard.unlock();

    queue.clear();

    subscriber = null;
    subscriber_context = null;
}
