const std = @import("std");

const assert = std.debug.assert;

pub const events_max: u32 = 64;
pub const height_max: u32 = 320;
pub const margin_max: u32 = 256;
pub const name_bytes_max: u32 = 64;
pub const scale_max: u32 = 2;
pub const surfaces_max: u32 = 2;
pub const width_max: u32 = 512;
pub const ready_yield_max: u32 = 1 << 22;

pub const frame_pixels_max: u32 = width_max * scale_max * height_max * scale_max;

comptime {
    assert(events_max > 1);
    assert(height_max > 0);
    assert(margin_max > 0);
    assert(name_bytes_max > 0);
    assert(scale_max >= 1);
    assert(surfaces_max > 0);
    assert(width_max > 0);
    assert(frame_pixels_max == width_max * height_max * scale_max * scale_max);
}

pub const Capabilities = struct {
    input: bool,
    present: bool,
};

pub const capability_count: u8 = @typeInfo(Capabilities).@"struct".fields.len;

pub const Anchor = enum(u8) {
    bottom_right = 0,
    top_right = 1,
    center = 2,

    pub fn is_valid(anchor: Anchor) bool {
        return @intFromEnum(anchor) <= @intFromEnum(Anchor.center);
    }
};

pub const Key = enum(u8) {
    escape = 0,
    enter = 1,
    space = 2,
    left = 3,
    right = 4,
    up = 5,
    down = 6,
    other = 7,
    pub fn is_valid(anchor: Key) bool {
        return @intFromEnum(anchor) <= @intFromEnum(Key.other);
    }
};

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn eql(point: Point, other: Point) bool {
        return point.x == other.x and point.y == other.y;
    }
};

pub const InputKind = enum(u8) {
    pointer_move = 0,
    pointer_down = 1,
    pointer_up = 2,
    pointer_leave = 3,
    key_down = 4,
    focus_lost = 5,
};

pub const InputEvent = union(InputKind) {
    pointer_move: Point,
    pointer_down: Point,
    pointer_up: Point,
    pointer_leave: void,
    key_down: Key,
    focus_lost: void,

    pub fn at(event: InputEvent) ?Point {
        const result = switch (event) {
            .pointer_move, .pointer_down, .pointer_up => |point| point,
            else => null,
        };

        return result;
    }
};

pub const Handle = struct {
    generation: u16 = 0,
    index: u16 = 0,

    pub fn eql(handle: Handle, other: Handle) bool {
        return handle.generation == other.generation and handle.index == other.index;
    }

    pub fn is_valid(handle: Handle) bool {
        return handle.generation > 0 and handle.index < surfaces_max;
    }
};

pub const Event = struct {
    handle: Handle = .{},
    input: InputEvent = .{ .focus_lost = {} },
};

pub const EventList = struct {
    count: u32 = 0,
    items: [events_max]Event = @splat(.{}),

    pub fn init() EventList {
        const result = EventList{};

        assert(result.is_empty());

        return result;
    }

    pub fn append(list: *EventList, event: Event) EventError!void {
        if (list.count >= events_max) {
            return EventError.TooMany;
        }

        list.items[list.count] = event;
        list.count += 1;

        assert(list.count <= events_max);
    }

    pub fn clear(list: *EventList) void {
        list.count = 0;

        assert(list.is_empty());
    }

    pub fn is_empty(list: *const EventList) bool {
        return list.count == 0;
    }

    pub fn slice(event_list: *const EventList) []const Event {
        assert(event_list.count <= events_max);

        return event_list.items[0..event_list.count];
    }
};

pub const EventQueue = struct {
    count: u32 = 0,
    drops: u32 = 0,
    head: u32 = 0,
    items: [events_max]Event = @splat(.{}),

    pub fn push(event_list: *EventQueue, event: Event) void {
        assert(event_list.count <= events_max);

        if (event_list.count == events_max) {
            event_list.head = (event_list.head + 1) % events_max;
            event_list.count -= 1;
            event_list.drops += 1;
        }

        const tail = (event_list.head + event_list.count) % events_max;

        event_list.items[tail] = event;
        event_list.count += 1;

        assert(event_list.count <= events_max);
    }

    pub fn drain(event_list: *EventQueue, list: *EventList) u32 {
        assert(event_list.count <= events_max);

        list.clear();

        var moved: u32 = 0;

        while (moved < event_list.count) : (moved += 1) {
            assert(moved < events_max);

            const index = (event_list.head + moved) % events_max;

            list.append(event_list.items[index]) catch {
                break;
            };
        }

        event_list.head = (event_list.head + moved) % events_max;
        event_list.count -= moved;

        assert(list.count == moved);

        return moved;
    }

    pub fn clear(event_list: *EventQueue) void {
        event_list.count = 0;
        event_list.drops = 0;
        event_list.head = 0;

        assert(event_list.is_empty());
    }

    pub fn is_empty(event_list: *const EventQueue) bool {
        return event_list.count == 0;
    }
};

pub const RuntimeConfig = struct {
    name: []const u8,

    pub fn is_valid(event_list: *const RuntimeConfig) bool {
        return event_list.name.len > 0 and event_list.name.len <= name_bytes_max;
    }
};

pub const SurfaceConfig = struct {
    anchor: Anchor = .bottom_right,
    height: u32 = 0,
    margin: u32 = 0,
    name: []const u8 = "",
    width: u32 = 0,

    pub fn is_valid(event_list: *const SurfaceConfig) bool {
        if (event_list.name.len == 0 or event_list.name.len > name_bytes_max) {
            return false;
        }

        if (event_list.width == 0 or event_list.width > width_max) {
            return false;
        }

        if (event_list.height == 0 or event_list.height > height_max) {
            return false;
        }

        if (event_list.margin > margin_max) {
            return false;
        }

        return event_list.anchor.is_valid();
    }
};

pub const Slot = struct {
    anchor: Anchor = .bottom_right,
    generation: u16 = 0,
    height: u32 = 0,
    margin: u32 = 0,
    name: [name_bytes_max]u8 = @splat(0),
    name_len: u16 = 0,
    scale: u32 = 1,
    used: bool = false,
    visible: bool = false,
    width: u32 = 0,

    pub fn get_name(event_list: *const Slot) []const u8 {
        assert(event_list.name_len <= name_bytes_max);

        return event_list.name[0..event_list.name_len];
    }

    pub fn pixel_count(event_list: *const Slot) u32 {
        assert(event_list.scale >= 1);
        assert(event_list.scale <= scale_max);

        const result = event_list.width * event_list.scale * event_list.height * event_list.scale;

        assert(result <= frame_pixels_max);

        return result;
    }

    pub fn set_name(event_list: *Slot, name: []const u8) void {
        const length: u16 = @intCast(@min(name.len, name_bytes_max));

        @memcpy(event_list.name[0..length], name[0..length]);

        event_list.name_len = length;

        assert(event_list.name_len <= name_bytes_max);
    }
};

pub const SurfaceTable = struct {
    next_generation: u16 = 1,
    slots: [surfaces_max]Slot = @splat(.{}),

    pub fn acquire(event_list: *SurfaceTable, config: *const SurfaceConfig) SurfaceError!Handle {
        if (!config.is_valid()) {
            return SurfaceError.Invalid;
        }

        var index: u16 = 0;

        while (index < surfaces_max) : (index += 1) {
            if (!event_list.slots[index].used) {
                break;
            }
        }

        if (index == surfaces_max) {
            return SurfaceError.TooMany;
        }

        const generation = event_list.next_generation;

        event_list.next_generation +%= 1;

        if (event_list.next_generation == 0) {
            event_list.next_generation = 1;
        }

        var slot = &event_list.slots[index];

        slot.* = Slot{
            .anchor = config.anchor,
            .generation = generation,
            .height = config.height,
            .margin = config.margin,
            .scale = 1,
            .used = true,
            .visible = false,
            .width = config.width,
        };

        slot.set_name(config.name);

        const result = Handle{ .generation = generation, .index = index };

        assert(result.is_valid());

        return result;
    }

    pub fn clear(event_list: *SurfaceTable) void {
        var index: u32 = 0;

        while (index < surfaces_max) : (index += 1) {
            assert(index < surfaces_max);

            event_list.slots[index] = Slot{};
        }

        assert(event_list.count() == 0);
    }

    pub fn count(event_list: *const SurfaceTable) u32 {
        var index: u32 = 0;
        var total: u32 = 0;

        while (index < surfaces_max) : (index += 1) {
            assert(index < surfaces_max);

            if (event_list.slots[index].used) {
                total += 1;
            }
        }

        assert(total <= surfaces_max);

        return total;
    }

    pub fn release(event_list: *SurfaceTable, handle: Handle) void {
        const slot = event_list.resolve(handle) orelse return;

        slot.* = Slot{};

        assert(!event_list.slots[handle.index].used);
    }

    pub fn resolve(event_list: *SurfaceTable, handle: Handle) ?*Slot {
        if (!handle.is_valid()) {
            return null;
        }

        const slot = &event_list.slots[handle.index];

        if (!slot.used or slot.generation != handle.generation) {
            return null;
        }

        return slot;
    }
};

pub const FrameStore = struct {
    pixels: [surfaces_max][frame_pixels_max]u32 = @splat(@splat(0)),

    pub fn clear(event_list: *FrameStore, index: u16) void {
        assert(index < surfaces_max);

        @memset(&event_list.pixels[index], 0);
    }

    pub fn view(event_list: *FrameStore, index: u16, slot: *const Slot) []u32 {
        assert(index < surfaces_max);

        const total = slot.pixel_count();

        assert(total <= frame_pixels_max);

        return event_list.pixels[index][0..total];
    }
};

pub const EventCallback = *const fn (?*anyopaque) void;

pub fn wait_ready(comptime state: type) RuntimeError!void {
    var attempts: u32 = 0;

    while (attempts < ready_yield_max) : (attempts += 1) {
        assert(attempts < ready_yield_max);

        if (state.current() != .starting) {
            break;
        }

        std.Thread.yield() catch continue;
    }

    if (state.current() != .running) {
        return RuntimeError.Unavailable;
    }
}

pub const RuntimeError = error{
    AlreadyOpen,
    Failed,
    NotOpen,
    Unavailable,
};

pub const SurfaceError = error{
    Failed,
    Invalid,
    NotFound,
    NotOpen,
    TooMany,
};

pub const EventError = error{
    AlreadySubscribed,
    Failed,
    NotOpen,
    TooMany,
};

pub fn assert_backend(comptime backend: type) void {
    comptime {
        require_decl(backend, "capabilities", "backend");

        const capabilities = backend.capabilities;

        if (@TypeOf(capabilities) != Capabilities) {
            @compileError("kalymma backend capabilities must be a Capabilities value");
        }

        assert_runtime(backend);
        assert_surface(backend);
        assert_events(backend);
    }
}

fn assert_runtime(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "runtime", "backend");

    require_error_set(scope, "Error", RuntimeError, "runtime");

    require_fn(scope, "open", fn (RuntimeConfig) RuntimeError!void, "runtime");
    require_fn(scope, "close", fn () void, "runtime");
    require_fn(scope, "is_open", fn () bool, "runtime");
}

fn assert_surface(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "surface", "backend");

    require_error_set(scope, "Error", SurfaceError, "surface");

    require_fn(scope, "create", fn (*const SurfaceConfig) SurfaceError!Handle, "surface");
    require_fn(scope, "destroy", fn (Handle) void, "surface");
    require_fn(scope, "show", fn (Handle) SurfaceError!void, "surface");
    require_fn(scope, "hide", fn (Handle) void, "surface");
    require_fn(scope, "is_visible", fn (Handle) bool, "surface");
    require_fn(scope, "frame", fn (Handle) []u32, "surface");
    require_fn(scope, "present", fn (Handle) SurfaceError!void, "surface");
    require_fn(scope, "scale", fn (Handle) u32, "surface");
}

fn assert_events(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "events", "backend");

    require_error_set(scope, "Error", EventError, "events");

    require_fn(scope, "subscribe", fn (EventCallback, ?*anyopaque) EventError!void, "events");
    require_fn(scope, "unsubscribe", fn () void, "events");
    require_fn(scope, "is_subscribed", fn () bool, "events");
    require_fn(scope, "poll", fn (*EventList) u32, "events");
    require_fn(scope, "drops", fn () u32, "events");
}

fn RequiredNamespaceType(
    comptime scope: type,
    comptime name: []const u8,
    comptime label: []const u8,
) type {
    require_decl(scope, name, label);

    const Namespace = @field(scope, name);

    if (@TypeOf(Namespace) != type) {
        @compileError(
            "kalymma backend " ++ label ++ "." ++ name ++ " must be a namespace, found " ++
                @typeName(@TypeOf(Namespace)),
        );
    }

    return Namespace;
}

fn require_decl(comptime scope: type, comptime name: []const u8, comptime label: []const u8) void {
    if (!@hasDecl(scope, name)) {
        @compileError("kalymma backend " ++ label ++ " is missing declaration '" ++ name ++ "'");
    }
}

fn require_fn(
    comptime scope: type,
    comptime name: []const u8,
    comptime Signature: type,
    comptime label: []const u8,
) void {
    require_decl(scope, name, label);

    const Actual = @TypeOf(@field(scope, name));

    if (Actual != Signature) {
        @compileError(
            "kalymma backend " ++ label ++ "." ++ name ++ " has type " ++ @typeName(Actual) ++
                ", expected " ++ @typeName(Signature),
        );
    }
}

fn require_error_set(
    comptime scope: type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime label: []const u8,
) void {
    require_decl(scope, name, label);

    const Actual = @field(scope, name);

    if (Actual != Expected) {
        @compileError(
            "kalymma backend " ++ label ++ "." ++ name ++ " is " ++ @typeName(Actual) ++
                ", expected the canonical set " ++ @typeName(Expected),
        );
    }
}

const testing = std.testing;

test "the capability set is fixed" {
    try testing.expectEqual(@as(u8, 2), capability_count);
}

test "every anchor and key in the vocabulary validates" {
    try testing.expect(Anchor.bottom_right.is_valid());
    try testing.expect(Anchor.top_right.is_valid());
    try testing.expect(Anchor.center.is_valid());
    try testing.expect(Key.escape.is_valid());
    try testing.expect(Key.other.is_valid());
}

test "only pointer events carry a position" {
    const moved = InputEvent{ .pointer_move = .{ .x = 3, .y = 4 } };
    const pressed = InputEvent{ .key_down = .enter };

    const point = moved.at() orelse return error.MissingPoint;

    try testing.expect(point.eql(.{ .x = 3, .y = 4 }));
    try testing.expect(pressed.at() == null);
}

test "a zero handle is never valid" {
    const empty = Handle{};
    const live = Handle{ .generation = 1, .index = 0 };

    try testing.expect(!empty.is_valid());
    try testing.expect(live.is_valid());
    try testing.expect(!live.eql(empty));
}

test "a configuration outside the contract bounds is refused" {
    const good = SurfaceConfig{ .height = 220, .name = "widget", .width = 380 };
    const nameless = SurfaceConfig{ .height = 220, .name = "", .width = 380 };
    const wide = SurfaceConfig{ .height = 220, .name = "widget", .width = width_max + 1 };
    const tall = SurfaceConfig{ .height = height_max + 1, .name = "widget", .width = 380 };

    const distant = SurfaceConfig{
        .height = 220,
        .margin = margin_max + 1,
        .name = "widget",
        .width = 380,
    };

    try testing.expect(good.is_valid());
    try testing.expect(!nameless.is_valid());
    try testing.expect(!wide.is_valid());
    try testing.expect(!tall.is_valid());
    try testing.expect(!distant.is_valid());
}

test "a runtime configuration needs a bounded name" {
    const good = RuntimeConfig{ .name = "mute" };
    const empty = RuntimeConfig{ .name = "" };
    const long = RuntimeConfig{ .name = "x" ** (name_bytes_max + 1) };

    try testing.expect(good.is_valid());
    try testing.expect(!empty.is_valid());
    try testing.expect(!long.is_valid());
}

test "the table fills to its bound and then reports the overflow" {
    var table = SurfaceTable{};

    const config = SurfaceConfig{ .height = 220, .name = "widget", .width = 380 };

    var index: u32 = 0;

    while (index < surfaces_max) : (index += 1) {
        _ = try table.acquire(&config);
    }

    try testing.expectEqual(surfaces_max, table.count());
    try testing.expectError(SurfaceError.TooMany, table.acquire(&config));

    table.clear();

    try testing.expectEqual(@as(u32, 0), table.count());
}

test "a released handle never resolves again" {
    var table = SurfaceTable{};

    const config = SurfaceConfig{ .height = 220, .name = "widget", .width = 380 };

    const first = try table.acquire(&config);

    try testing.expect(table.resolve(first) != null);

    table.release(first);

    try testing.expect(table.resolve(first) == null);

    const second = try table.acquire(&config);

    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);
    try testing.expect(table.resolve(first) == null);
    try testing.expect(table.resolve(second) != null);
}

test "an invalid configuration never occupies a slot" {
    var table = SurfaceTable{};

    const config = SurfaceConfig{ .height = 0, .name = "widget", .width = 380 };

    try testing.expectError(SurfaceError.Invalid, table.acquire(&config));
    try testing.expectEqual(@as(u32, 0), table.count());
}

test "a slot remembers its name and sizes its frame" {
    var table = SurfaceTable{};

    const config = SurfaceConfig{ .height = 220, .name = "widget", .width = 380 };

    const handle = try table.acquire(&config);
    const slot = table.resolve(handle) orelse return error.MissingSlot;

    try testing.expectEqualStrings("widget", slot.get_name());
    try testing.expectEqual(@as(u32, 380 * 220), slot.pixel_count());

    slot.scale = 2;

    try testing.expectEqual(@as(u32, 380 * 220 * 4), slot.pixel_count());
}

test "an over long surface name is truncated rather than overflowing" {
    var slot = Slot{};

    slot.set_name("n" ** (name_bytes_max + 32));

    try testing.expectEqual(@as(u16, name_bytes_max), slot.name_len);
}

test "the queue drains in order and stays empty afterwards" {
    var queue = EventQueue{};
    var list = EventList.init();

    const handle = Handle{ .generation = 1, .index = 0 };

    queue.push(.{ .handle = handle, .input = .{ .pointer_move = .{ .x = 1, .y = 1 } } });
    queue.push(.{ .handle = handle, .input = .{ .pointer_move = .{ .x = 2, .y = 2 } } });

    try testing.expectEqual(@as(u32, 2), queue.drain(&list));
    try testing.expectEqual(@as(u32, 2), list.count);
    try testing.expect(queue.is_empty());
    try testing.expectEqual(@as(i32, 1), list.items[0].input.pointer_move.x);
    try testing.expectEqual(@as(i32, 2), list.items[1].input.pointer_move.x);
    try testing.expectEqual(@as(u32, 0), queue.drain(&list));
}

test "an overflowing queue drops the oldest event and counts the loss" {
    var queue = EventQueue{};
    var list = EventList.init();

    var index: u32 = 0;

    while (index < events_max + 3) : (index += 1) {
        queue.push(.{ .input = .{ .pointer_move = .{ .x = @intCast(index), .y = 0 } } });
    }

    try testing.expectEqual(@as(u32, 3), queue.drops);
    try testing.expectEqual(events_max, queue.drain(&list));
    try testing.expectEqual(@as(i32, 3), list.items[0].input.pointer_move.x);
}

test "the queue keeps wrapping after a partial drain" {
    var queue = EventQueue{};
    var list = EventList.init();

    var index: u32 = 0;

    while (index < events_max) : (index += 1) {
        queue.push(.{ .input = .{ .pointer_move = .{ .x = @intCast(index), .y = 0 } } });
    }

    _ = queue.drain(&list);

    queue.push(.{ .input = .{ .key_down = .escape } });

    try testing.expectEqual(@as(u32, 1), queue.drain(&list));
    try testing.expectEqual(Key.escape, list.items[0].input.key_down);
}

test "a list refuses more than the contract bound" {
    var list = EventList.init();

    var index: u32 = 0;

    while (index < events_max) : (index += 1) {
        try list.append(.{});
    }

    try testing.expectError(EventError.TooMany, list.append(.{}));
    try testing.expectEqual(@as(usize, events_max), list.slice().len);
}

test "a frame view covers exactly the surface pixels" {
    var store = FrameStore{};

    const slot = Slot{ .height = 220, .scale = 1, .used = true, .width = 380 };

    const pixels = store.view(0, &slot);

    try testing.expectEqual(@as(usize, 380 * 220), pixels.len);

    pixels[0] = 0xFFFFFFFF;

    store.clear(0);

    try testing.expectEqual(@as(u32, 0), store.pixels[0][0]);
}
