const std = @import("std");

const event_module = @import("../event.zig");
const Fault = @import("fake/fault.zig");
const geometry = @import("geometry.zig");
const interface = @import("interface.zig");
const monitor_module = @import("../monitor.zig");
const shade_module = @import("../shade.zig");
const surface_module = @import("../surface.zig");

const assert = std.debug.assert;

const CapacityError = surface_module.CapacityError;
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Fake = @This();
const FrameStore = interface.FrameStore;
const Listener = interface.Listener;
const Monitor = monitor_module.Monitor;
const PlatformError = interface.PlatformError;
const Queue = event_module.Queue;
const Rect = geometry.Rect;
const RequestError = surface_module.RequestError;
const Shade = shade_module.Shade;
const ShadeCapacityError = shade_module.CapacityError;
const ShadeOptions = Shade.Options;
const ShadeRequestError = shade_module.RequestError;
const ShadeSlot = interface.ShadeSlot;
const ShadeTable = interface.ShadeTable;
const Slot = interface.Slot;
const Surface = surface_module.Surface;
const SurfaceOptions = Surface.Options;
const Table = interface.Table;

counts: [call_count]u32 = @splat(0),
fault: Fault = .{},
frames: FrameStore = .{},
monitors: Monitor.List = monitors_default(),
queue: Queue = .{},
shade_table: ShadeTable = .{},
subscriber: ?Listener = null,
subscriber_context: ?*anyopaque = null,
table: Table = .{},
tint: ?u32 = null,
tint_supported: bool = false,

pub const Call = enum(u8) {
    events_subscribe = 0,
    events_unsubscribe = 1,
    init = 2,
    shade_create = 3,
    shade_destroy = 4,
    shade_fill = 5,
    shade_place = 6,
    shade_set_cursor = 7,
    surface_create = 8,
    surface_destroy = 9,
    surface_hide = 10,
    surface_present = 11,
    surface_show = 12,
    tint_apply = 13,
    tint_clear = 14,
};

pub const Options = struct {
    fault: ?Call = null,
};

pub const call_count: u32 = @typeInfo(Call).@"enum".field_names.len;
pub const monitor_default = Monitor.init("fake", .{ .height = 1080, .width = 1920 });

comptime {
    assert(call_count == 15);
    assert(monitor_default.rect.width > 0);

    interface.assert_backend(Fake);
}

pub fn init(fake: *Fake, options: Options) PlatformError!void {
    fake.* = .{};

    if (options.fault) |call| fake.fault.arm(call);

    fake.record(.init);

    if (fake.fault.is_armed(.init)) {
        return error.DisplayUnavailable;
    }

    assert(fake.table.count() == 0);
    assert(fake.queue.is_empty());
}

pub fn deinit(fake: *Fake) void {
    fake.set_subscriber(null, null);
    fake.shade_table.clear();
    fake.table.clear();
    fake.set_tint(null);

    assert(!fake.events_is_subscribed());
    assert(fake.shade_table.count() == 0);
    assert(fake.table.count() == 0);
    assert(fake.tint_of() == null);

    fake.* = undefined;
}

pub fn events_is_subscribed(fake: *Fake) bool {
    return fake.subscriber != null;
}

pub fn events_poll(fake: *Fake, list: *Event.List) u32 {
    const result = fake.queue.drain(list);

    assert(result == list.count);
    assert(result <= event_module.count_max);

    return result;
}

pub fn events_subscribe(fake: *Fake, listener: Listener, context: *anyopaque) void {
    assert(!fake.events_is_subscribed());

    fake.record(.events_subscribe);
    fake.set_subscriber(listener, context);

    assert(fake.events_is_subscribed());
}

pub fn events_unsubscribe(fake: *Fake) void {
    fake.record(.events_unsubscribe);
    fake.set_subscriber(null, null);

    assert(!fake.events_is_subscribed());
}

pub fn monitors_list(fake: *Fake, target: *Monitor.List) u32 {
    const result = fake.copy_monitors(target);

    assert(result == target.count);
    assert(result <= monitor_module.count_max);

    return result;
}

pub fn shade_create(
    fake: *Fake,
    options: *const ShadeOptions,
) (ShadeCapacityError || PlatformError)!Shade {
    assert(options.is_valid());

    fake.record(.shade_create);

    if (fake.fault.is_armed(.shade_create)) {
        return error.ShadeCreateFailed;
    }

    const shade = try fake.shade_table.acquire(options);

    assert(fake.shade_table.resolve(shade) != null);

    return shade;
}

pub fn shade_destroy(fake: *Fake, shade: Shade) void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    fake.record(.shade_destroy);
    fake.shade_table.release(shade);

    assert(fake.shade_table.resolve(shade) == null);
}

pub fn shade_fill(
    fake: *Fake,
    shade: Shade,
    color: u32,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    fake.record(.shade_fill);

    if (fake.fault.is_armed(.shade_fill)) {
        return error.ShadeUpdateFailed;
    }

    const slot = fake.shade_table.resolve(shade) orelse return error.ShadeUnknown;

    slot.color = color;

    assert(slot.color == color);
}

pub fn shade_place(
    fake: *Fake,
    shade: Shade,
    rect: Rect,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(!rect.is_empty());

    fake.record(.shade_place);

    if (fake.fault.is_armed(.shade_place)) {
        return error.ShadeUpdateFailed;
    }

    const slot = fake.shade_table.resolve(shade) orelse return error.ShadeUnknown;

    slot.rect = rect;

    assert(std.meta.eql(slot.rect, rect));
}

pub fn shade_set_cursor(
    fake: *Fake,
    shade: Shade,
    cursor: Cursor,
) (PlatformError || ShadeRequestError)!void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(shade_module.unpack(shade).index < shade_module.count_max);

    fake.record(.shade_set_cursor);

    if (fake.fault.is_armed(.shade_set_cursor)) {
        return error.ShadeUpdateFailed;
    }

    const slot = fake.shade_table.resolve(shade) orelse return error.ShadeUnknown;

    slot.cursor = cursor;

    assert(slot.cursor == cursor);
}

pub fn surface_create(
    fake: *Fake,
    options: *const SurfaceOptions,
) (CapacityError || PlatformError)!Surface {
    assert(options.is_valid());

    fake.record(.surface_create);

    if (fake.fault.is_armed(.surface_create)) {
        return error.SurfaceCreateFailed;
    }

    const surface = try fake.acquire(options);

    assert(fake.resolve(surface) != null);

    return surface;
}

pub fn surface_destroy(fake: *Fake, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    fake.record(.surface_destroy);
    fake.release(surface);

    assert(fake.resolve(surface) == null);
}

pub fn surface_frame(fake: *Fake, surface: Surface) []u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return fake.frame_of(surface);
}

pub fn surface_hide(fake: *Fake, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    fake.record(.surface_hide);

    const slot = fake.resolve(surface) orelse return;

    slot.visible = false;

    assert(!slot.visible);
}

pub fn surface_is_visible(fake: *const Fake, surface: Surface) bool {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return fake.table.is_visible(surface);
}

pub fn surface_present(fake: *Fake, surface: Surface) (PlatformError || RequestError)!void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    fake.record(.surface_present);

    if (fake.fault.is_armed(.surface_present)) {
        return error.SurfacePresentFailed;
    }

    if (fake.resolve(surface) == null) {
        return error.SurfaceUnknown;
    }
}

pub fn surface_show(fake: *Fake, surface: Surface) (PlatformError || RequestError)!void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    fake.record(.surface_show);

    if (fake.fault.is_armed(.surface_show)) {
        return error.SurfaceShowFailed;
    }

    const slot = fake.resolve(surface) orelse return error.SurfaceUnknown;

    slot.visible = true;

    assert(slot.visible);
}

pub fn tint_apply(fake: *Fake, color: u32) PlatformError!void {
    assert(fake.tint_is_supported());

    fake.record(.tint_apply);

    if (fake.fault.is_armed(.tint_apply)) {
        return error.TintFailed;
    }

    fake.set_tint(color);

    assert(fake.tint_of() != null);
}

pub fn tint_clear(fake: *Fake) void {
    fake.record(.tint_clear);
    fake.set_tint(null);

    assert(fake.tint_of() == null);
}

pub fn tint_is_supported(fake: *Fake) bool {
    return fake.tint_supported;
}

pub fn checksum(fake: *Fake, surface: Surface) u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    const pixels = fake.frame_of(surface);

    var total: u32 = 2166136261;

    for (pixels) |pixel| {
        total = (total ^ pixel) *% 16777619;
    }

    return total;
}

pub fn count_of(fake: *const Fake, call: Call) u32 {
    const index = @backingInt(call);

    assert(index < call_count);

    return fake.counts[index];
}

pub fn drops(fake: *const Fake) u32 {
    return fake.queue.drops;
}

pub fn inject(fake: *Fake, surface: Surface, input: Event.Input) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(input != .monitors_changed);

    fake.queue.push(.{ .input = input, .source = .{ .surface = surface } });

    fake.notify();
}

pub fn inject_shade(fake: *Fake, shade: Shade, input: Event.Input) void {
    assert(shade_module.unpack(shade).generation > 0);
    assert(input != .monitors_changed);

    fake.queue.push(.{ .input = input, .source = .{ .shade = shade } });

    fake.notify();
}

pub fn pending(fake: *const Fake) u32 {
    return fake.queue.count;
}

pub fn set_monitors(fake: *Fake, list: *const Monitor.List) void {
    assert(list.count <= monitor_module.count_max);

    if (fake.monitors.eql(list)) {
        return;
    }

    fake.monitors = list.*;
    fake.queue.push(.{ .input = .{ .monitors_changed = {} }, .source = .{ .display = {} } });

    fake.notify();

    assert(fake.monitors.eql(list));
}

pub fn set_tint_supported(fake: *Fake, value: bool) void {
    fake.tint_supported = value;
}

pub fn shade_of(fake: *Fake, shade: Shade) ?ShadeSlot {
    assert(shade_module.unpack(shade).generation > 0);

    const slot = fake.shade_table.resolve(shade) orelse return null;
    return slot.*;
}

pub fn tint_of(fake: *const Fake) ?u32 {
    return fake.tint;
}

fn acquire(fake: *Fake, options: *const SurfaceOptions) CapacityError!Surface {
    assert(options.is_valid());

    const surface = try fake.table.acquire(options);

    fake.frames.clear(surface_module.unpack(surface).index);

    return surface;
}

fn copy_monitors(fake: *const Fake, target: *Monitor.List) u32 {
    assert(fake.monitors.count <= monitor_module.count_max);

    target.* = fake.monitors;

    return target.count;
}

fn frame_of(fake: *Fake, surface: Surface) []u32 {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    const slot = fake.table.resolve(surface) orelse return &.{};
    return fake.frames.view(surface_module.unpack(surface).index, slot);
}

fn monitors_default() Monitor.List {
    var result = Monitor.List.init();

    result.append(monitor_default);

    assert(result.count == 1);

    return result;
}

fn notify(fake: *const Fake) void {
    const listener = fake.subscriber orelse return;
    const context = fake.subscriber_context orelse return;

    listener(context);
}

fn record(fake: *Fake, call: Call) void {
    const index = @backingInt(call);

    assert(index < call_count);

    fake.counts[index] += 1;
}

fn release(fake: *Fake, surface: Surface) void {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    if (fake.table.resolve(surface) == null) {
        return;
    }

    fake.frames.clear(surface_module.unpack(surface).index);
    fake.table.release(surface);
}

fn resolve(fake: *Fake, surface: Surface) ?*Slot {
    assert(surface_module.unpack(surface).generation > 0);
    assert(surface_module.unpack(surface).index < surface_module.count_max);

    return fake.table.resolve(surface);
}

fn set_subscriber(fake: *Fake, listener: ?Listener, context: ?*anyopaque) void {
    if (listener != null) assert(context != null);
    if (listener == null) assert(context == null);

    fake.subscriber = listener;
    fake.subscriber_context = context;
}

fn set_tint(fake: *Fake, color: ?u32) void {
    fake.tint = color;
}

const testing = std.testing;

const widget = SurfaceOptions{ .height = 8, .name = "widget", .width = 8 };

fn open() !*Fake {
    const fake = try testing.allocator.create(Fake);
    errdefer testing.allocator.destroy(fake);

    try fake.init(.{});

    return fake;
}

fn close(fake: *Fake) void {
    fake.deinit();
    testing.allocator.destroy(fake);
}

test "an initialized fake is empty, unsubscribed, and has recorded only its init" {
    const fake = try open();
    defer close(fake);

    try testing.expect(!fake.events_is_subscribed());
    try testing.expectEqual(@as(u32, 0), fake.table.count());
    try testing.expectEqual(@as(u32, 0), fake.pending());
    try testing.expectEqual(@as(u32, 1), fake.count_of(.init));
    try testing.expectEqual(@as(u32, 0), fake.count_of(.surface_create));
}

test "recorded calls accumulate and a fresh init starts them from zero" {
    const fake = try open();
    defer close(fake);

    fake.record(.surface_show);
    fake.record(.surface_show);
    fake.record(.surface_hide);

    try testing.expectEqual(@as(u32, 2), fake.count_of(.surface_show));
    try testing.expectEqual(@as(u32, 1), fake.count_of(.surface_hide));

    fake.deinit();

    try fake.init(.{});

    try testing.expectEqual(@as(u32, 0), fake.count_of(.surface_show));
}

test "a fault armed through the options fails the init it names and waits for any other" {
    const fake = try testing.allocator.create(Fake);
    defer testing.allocator.destroy(fake);

    try testing.expectError(error.DisplayUnavailable, fake.init(.{ .fault = .init }));

    try fake.init(.{ .fault = .surface_show });
    defer fake.deinit();

    const surface = try fake.surface_create(&widget);

    try testing.expect(fake.fault.is_armed(.surface_show));
    try testing.expectError(error.SurfaceShowFailed, fake.surface_show(surface));
}

test "a frame checksum changes with the pixels written into it" {
    const fake = try open();
    defer close(fake);

    const surface = try fake.acquire(&widget);
    const before = fake.checksum(surface);
    const pixels = fake.frame_of(surface);

    try testing.expectEqual(@as(usize, 64), pixels.len);

    pixels[0] = 0xFF00FF00;

    try testing.expect(fake.checksum(surface) != before);

    fake.release(surface);

    try testing.expectEqual(@as(usize, 0), fake.frame_of(surface).len);
}

test "an injected event wakes the subscriber and drains once" {
    const fake = try open();
    defer close(fake);

    var wakes: u32 = 0;

    fake.set_subscriber(on_wake, &wakes);

    const surface = surface_module.pack(0, 1);

    fake.inject(surface, .{ .key_down = .escape });

    try testing.expectEqual(@as(u32, 1), wakes);
    try testing.expectEqual(@as(u32, 1), fake.pending());

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 1), fake.events_poll(&list));
    try testing.expectEqual(@as(u32, 0), fake.pending());
    try testing.expectEqual(event_module.Key.escape, list.slice()[0].input.key_down);
}

test "a monitor change wakes the subscriber once and an unchanged list stays quiet" {
    const fake = try open();
    defer close(fake);

    var wakes: u32 = 0;
    var changed = Monitor.List.init();

    fake.set_subscriber(on_wake, &wakes);

    changed.append(Monitor.init("left", .{ .height = 1080, .width = 1920 }));
    changed.append(Monitor.init("right", .{ .height = 1080, .width = 1920, .x = 1920 }));

    fake.set_monitors(&changed);
    fake.set_monitors(&changed);

    var list = Event.List.init();
    var copied = Monitor.List.init();

    try testing.expectEqual(@as(u32, 1), wakes);
    try testing.expectEqual(@as(u32, 1), fake.events_poll(&list));
    try testing.expect(list.slice()[0].source == .display);
    try testing.expectEqual(@as(u32, 2), fake.copy_monitors(&copied));
    try testing.expectEqualStrings("right", copied.slice()[1].get_name());
}

fn on_wake(context: *anyopaque) void {
    const wakes: *u32 = @ptrCast(@alignCast(context));

    wakes.* += 1;
}
