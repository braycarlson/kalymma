const std = @import("std");

const contract = @import("../contract.zig");
const event_module = @import("../../event.zig");
const surface_module = @import("../../surface.zig");

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

pub const Call = enum(u8) {
    close = 0,
    create = 1,
    destroy = 2,
    hide = 3,
    open = 4,
    present = 5,
    show = 6,
    subscribe = 7,
    unsubscribe = 8,
};

pub const call_count: u32 = @typeInfo(Call).@"enum".field_names.len;

comptime {
    assert(call_count == 9);
}

var counts: [call_count]u32 = @splat(0);
var failure: ?Call = null;
var frames: FrameStore = .{};
var opened: bool = false;
var queue: Queue = .{};
var subscriber: ?Listener = null;
var subscriber_context: ?*anyopaque = null;
var table: Table = .{};

pub fn reset() void {
    counts = @splat(0);
    failure = null;
    opened = false;
    subscriber = null;
    subscriber_context = null;

    queue.clear();
    table.clear();

    var index: u16 = 0;

    while (index < surface_module.surface_count_max) : (index += 1) {
        frames.clear(index);
    }

    assert(!opened);
    assert(table.count() == 0);
    assert(queue.is_empty());
}

pub fn record(call: Call) void {
    const index = @backingInt(call);

    assert(index < call_count);

    counts[index] += 1;
}

pub fn count_of(call: Call) u32 {
    const index = @backingInt(call);

    assert(index < call_count);

    return counts[index];
}

pub fn fail(call: Call) void {
    failure = call;

    assert(failure != null);
}

pub fn clear_failure() void {
    failure = null;

    assert(failure == null);
}

pub fn should_fail(call: Call) bool {
    const wanted = failure orelse return false;
    return wanted == call;
}

pub fn is_open() bool {
    return opened;
}

pub fn mark_open() void {
    assert(!opened);

    opened = true;
}

pub fn mark_closed() void {
    opened = false;

    assert(!opened);
}

pub fn surfaces() *Table {
    return &table;
}

pub fn acquire(options: *const Options) CapacityError!Surface {
    const surface = try table.acquire(options);

    frames.clear(surface_module.unpack(surface).index);

    return surface;
}

pub fn release(surface: Surface) void {
    if (table.resolve(surface) == null) {
        return;
    }

    frames.clear(surface_module.unpack(surface).index);
    table.release(surface);
}

pub fn resolve(surface: Surface) ?*Slot {
    return table.resolve(surface);
}

pub fn frame_of(surface: Surface) []u32 {
    const slot = table.resolve(surface) orelse return &.{};
    return frames.view(surface_module.unpack(surface).index, slot);
}

pub fn checksum(surface: Surface) u32 {
    const pixels = frame_of(surface);

    var total: u32 = 2166136261;

    for (pixels) |pixel| {
        total = (total ^ pixel) *% 16777619;
    }

    return total;
}

pub fn set_subscriber(listener: ?Listener, context: ?*anyopaque) void {
    subscriber = listener;
    subscriber_context = context;
}

pub fn is_subscribed() bool {
    return subscriber != null;
}

pub fn inject(surface: Surface, input: Event.Input) void {
    queue.push(.{ .input = input, .surface = surface });

    notify();
}

pub fn drain(list: *Event.List) u32 {
    return queue.drain(list);
}

pub fn drops() u32 {
    return queue.drops;
}

pub fn pending() u32 {
    return queue.count;
}

fn notify() void {
    const listener = subscriber orelse return;
    const context = subscriber_context orelse return;

    listener(context);
}

const testing = std.testing;

const widget = Options{ .height = 8, .name = "widget", .width = 8 };

test "a reset mock is closed, empty and unsubscribed" {
    reset();
    defer reset();

    try testing.expect(!is_open());
    try testing.expect(!is_subscribed());
    try testing.expectEqual(@as(u32, 0), surfaces().count());
    try testing.expectEqual(@as(u32, 0), pending());
    try testing.expectEqual(@as(u32, 0), count_of(.open));
}

test "recorded calls accumulate and reset clears them" {
    reset();
    defer reset();

    record(.open);
    record(.open);
    record(.close);

    try testing.expectEqual(@as(u32, 2), count_of(.open));
    try testing.expectEqual(@as(u32, 1), count_of(.close));

    reset();

    try testing.expectEqual(@as(u32, 0), count_of(.open));
}

test "a scripted failure fires for one call only" {
    reset();
    defer reset();

    fail(.create);

    try testing.expect(should_fail(.create));
    try testing.expect(!should_fail(.show));

    clear_failure();

    try testing.expect(!should_fail(.create));
}

test "a frame checksum changes with the pixels written into it" {
    reset();
    defer reset();

    const surface = try acquire(&widget);
    const before = checksum(surface);
    const pixels = frame_of(surface);

    try testing.expectEqual(@as(usize, 64), pixels.len);

    pixels[0] = 0xFF00FF00;

    try testing.expect(checksum(surface) != before);

    release(surface);

    try testing.expectEqual(@as(usize, 0), frame_of(surface).len);
}

test "an injected event wakes the subscriber and drains once" {
    reset();
    defer reset();

    var wakes: u32 = 0;

    set_subscriber(on_wake, &wakes);

    const surface = surface_module.pack(0, 1);

    inject(surface, .{ .key_down = .escape });

    try testing.expectEqual(@as(u32, 1), wakes);
    try testing.expectEqual(@as(u32, 1), pending());

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 1), drain(&list));
    try testing.expectEqual(@as(u32, 0), pending());
    try testing.expectEqual(event_module.Key.escape, list.slice()[0].input.key_down);
}

fn on_wake(context: *anyopaque) void {
    const wakes: *u32 = @ptrCast(@alignCast(context));

    wakes.* += 1;
}
