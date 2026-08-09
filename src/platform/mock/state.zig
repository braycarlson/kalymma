const std = @import("std");

const contract = @import("../contract.zig");

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

pub const name_bytes_max: u32 = contract.name_bytes_max;

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

pub const call_count: u32 = @typeInfo(Call).@"enum".fields.len;

comptime {
    assert(call_count == 9);
    assert(name_bytes_max > 0);
}

var counts: [call_count]u32 = @splat(0);
var failure: ?Call = null;
var frames: FrameStore = .{};
var name_length: u16 = 0;
var name_storage: [name_bytes_max]u8 = @splat(0);
var opened: bool = false;
var queue: EventQueue = .{};
var subscriber: ?EventCallback = null;
var subscriber_context: ?*anyopaque = null;
var table: SurfaceTable = .{};

pub fn reset() void {
    counts = @splat(0);
    failure = null;
    name_length = 0;
    opened = false;
    subscriber = null;
    subscriber_context = null;

    queue.clear();
    table.clear();

    var index: u16 = 0;

    while (index < contract.surfaces_max) : (index += 1) {
        assert(index < contract.surfaces_max);

        frames.clear(index);
    }

    assert(!opened);
    assert(table.count() == 0);
    assert(queue.is_empty());
}

pub fn record(call: Call) void {
    const index = @intFromEnum(call);

    assert(index < call_count);

    counts[index] += 1;
}

pub fn count_of(call: Call) u32 {
    const index = @intFromEnum(call);

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

pub fn set_open(value: bool) void {
    opened = value;
}

pub fn get_name() []const u8 {
    assert(name_length <= name_bytes_max);

    return name_storage[0..name_length];
}

pub fn set_name(name: []const u8) void {
    const length: u16 = @intCast(@min(name.len, name_bytes_max));

    @memcpy(name_storage[0..length], name[0..length]);

    name_length = length;

    assert(name_length <= name_bytes_max);
}

pub fn surfaces() *SurfaceTable {
    return &table;
}

pub fn acquire(config: *const SurfaceConfig) contract.SurfaceError!Handle {
    const handle = try table.acquire(config);

    frames.clear(handle.index);

    return handle;
}

pub fn release(handle: Handle) void {
    const slot = table.resolve(handle) orelse return;

    _ = slot;

    frames.clear(handle.index);
    table.release(handle);
}

pub fn resolve(handle: Handle) ?*Slot {
    return table.resolve(handle);
}

pub fn frame_of(handle: Handle) []u32 {
    const slot = table.resolve(handle) orelse return &.{};

    return frames.view(handle.index, slot);
}

pub fn checksum(handle: Handle) u32 {
    const pixels = frame_of(handle);

    var total: u32 = 2166136261;

    for (pixels) |pixel| {
        total = (total ^ pixel) *% 16777619;
    }

    return total;
}

pub fn set_subscriber(callback: ?EventCallback, context: ?*anyopaque) void {
    subscriber = callback;
    subscriber_context = context;
}

pub fn is_subscribed() bool {
    return subscriber != null;
}

pub fn inject(handle: Handle, input: InputEvent) void {
    queue.push(.{ .handle = handle, .input = input });

    notify();
}

pub fn drain(list: *EventList) u32 {
    return queue.drain(list);
}

pub fn drops() u32 {
    return queue.drops;
}

pub fn pending() u32 {
    return queue.count;
}

fn notify() void {
    const callback = subscriber orelse return;

    callback(subscriber_context);
}

const testing = std.testing;

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

    const config = SurfaceConfig{ .height = 8, .name = "widget", .width = 8 };

    const handle = try acquire(&config);
    const before = checksum(handle);

    const pixels = frame_of(handle);

    try testing.expectEqual(@as(usize, 64), pixels.len);

    pixels[0] = 0xFF00FF00;

    try testing.expect(checksum(handle) != before);

    release(handle);

    try testing.expectEqual(@as(usize, 0), frame_of(handle).len);
}

var wakes: u32 = 0;

fn on_wake(_: ?*anyopaque) void {
    wakes += 1;
}

test "an injected event wakes the subscriber and drains once" {
    reset();
    defer reset();

    wakes = 0;

    set_subscriber(on_wake, null);

    const handle = Handle{ .generation = 1, .index = 0 };

    inject(handle, .{ .key_down = .escape });

    try testing.expectEqual(@as(u32, 1), wakes);
    try testing.expectEqual(@as(u32, 1), pending());

    var list = EventList.init();

    try testing.expectEqual(@as(u32, 1), drain(&list));
    try testing.expectEqual(@as(u32, 0), pending());
    try testing.expectEqual(contract.Key.escape, list.items[0].input.key_down);
}
