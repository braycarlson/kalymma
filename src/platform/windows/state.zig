const std = @import("std");

const event_module = @import("../../event.zig");
const geometry = @import("../geometry.zig");
const interface = @import("../interface.zig");
const Magnifier = @import("magnifier.zig");
const monitor_module = @import("../../monitor.zig");
const shade_module = @import("../../shade.zig");
const surface_module = @import("../../surface.zig");
const win32 = @import("win32.zig");

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
const ShadeSlot = interface.ShadeSlot;
const ShadeTable = interface.ShadeTable;
const Slot = interface.Slot;
const State = @This();
const Surface = surface_module.Surface;
const Table = interface.Table;

controller: ?win32.HWND = null,
frames: FrameStore = .{},
magnifier: Magnifier = .{},
monitors: Monitor.List = .{ .count = 0, .items = @splat(.{}) },
mutex: Mutex = .{},
queue: Queue = .{},
shade_sequence: u32 = 0,
shade_table: ShadeTable = .{},
shade_windows: [shade_module.count_max]ShadeWindow = @splat(.{}),
status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(Status.idle)),
subscriber: ?Listener = null,
subscriber_context: ?*anyopaque = null,
table: Table = .{},
thread: ?std.Thread = null,
windows: [surface_module.count_max]Window = @splat(.{}),

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

pub const ShadeWindow = struct {
    brush: ?win32.HBRUSH = null,
    cursor: Cursor = .crosshair,
    frame: Rect = .{},
    handle: ?win32.HWND = null,
    sequence: u32 = 0,
};

pub fn lock(state: *State) void {
    state.mutex.lock();
}

pub fn unlock(state: *State) void {
    state.mutex.unlock();
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

pub fn get_controller(state: *const State) ?win32.HWND {
    return state.controller;
}

pub fn set_controller(state: *State, value: ?win32.HWND) void {
    if (value != null) assert(state.controller == null);
    if (value == null) assert(state.controller != null);

    state.controller = value;
}

pub fn window_at(state: *State, index: u16) *Window {
    assert(index < surface_module.count_max);

    return &state.windows[index];
}

pub fn shade_window_at(state: *State, index: u16) *ShadeWindow {
    assert(index < shade_module.count_max);

    return &state.shade_windows[index];
}

pub fn attach_shade_window(state: *State, index: u16, handle: win32.HWND) void {
    assert(index < shade_module.count_max);
    assert(state.shade_windows[index].handle == null);

    state.shade_sequence += 1;

    state.shade_windows[index] = .{ .handle = handle, .sequence = state.shade_sequence };

    assert(state.shade_windows[index].sequence > 0);
}

pub fn get_magnifier(state: *State) *Magnifier {
    if (state.magnifier.initialized) assert(state.magnifier.module != null);

    return &state.magnifier;
}

pub fn acquire(state: *State, options: *const Options) CapacityError!Surface {
    state.mutex.lock();
    defer state.mutex.unlock();

    const surface = try state.table.acquire(options);
    const index = surface_module.unpack(surface).index;

    state.frames.clear(index);

    state.windows[index] = Window{};

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

    state.windows = @splat(.{});
}

pub fn frame_of(state: *State, surface: Surface) []u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    const slot = state.table.resolve(surface) orelse return &.{};
    return state.frames.view(surface_module.unpack(surface).index, slot);
}

pub fn copy_frame(state: *State, index: u16, destination: [*]u32) void {
    assert(index < surface_module.count_max);

    state.mutex.lock();
    defer state.mutex.unlock();

    const slot = &state.table.slots[index];

    if (!slot.used) {
        return;
    }

    const pixels = state.frames.view(index, slot);

    @memcpy(destination[0..pixels.len], pixels);
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

    state.shade_windows = @splat(.{});
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
