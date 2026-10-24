const std = @import("std");

const event_module = @import("../event.zig");
const surface_module = @import("../surface.zig");

const assert = std.debug.assert;

const Anchor = surface_module.Anchor;
const CapacityError = surface_module.CapacityError;
const Event = event_module.Event;
const Options = surface_module.Options;
const RequestError = surface_module.RequestError;
const Surface = surface_module.Surface;

pub const Listener = *const fn (*anyopaque) void;

pub const PlatformError = error{
    DisplayUnavailable,
    SurfaceCreateFailed,
    SurfacePresentFailed,
    SurfaceShowFailed,
    ThreadSpawnFailed,
};

pub const Slot = struct {
    anchor: Anchor = .bottom_right,
    generation: u16 = 0,
    height: u32 = 0,
    margin: u32 = 0,
    name: [surface_module.name_bytes_max]u8 = @splat(0),
    name_len: u16 = 0,
    used: bool = false,
    visible: bool = false,
    width: u32 = 0,

    pub fn get_name(slot: *const Slot) []const u8 {
        assert(slot.name_len <= surface_module.name_bytes_max);

        return slot.name[0..slot.name_len];
    }

    pub fn pixel_count(slot: *const Slot) u32 {
        assert(slot.width <= surface_module.width_pixels_max);
        assert(slot.height <= surface_module.height_pixels_max);

        const result = slot.width * slot.height;

        assert(result <= frame_pixels_max);

        return result;
    }
};

pub const Table = struct {
    generation_next: u16 = 1,
    slots: [surface_module.surface_count_max]Slot = @splat(.{}),

    pub fn acquire(table: *Table, options: *const Options) CapacityError!Surface {
        assert(options.is_valid());

        var index: u16 = 0;

        while (index < surface_module.surface_count_max) : (index += 1) {
            if (!table.slots[index].used) {
                break;
            }
        }

        if (index == surface_module.surface_count_max) {
            return error.SurfacesExhausted;
        }

        const generation = table.generation_next;

        table.generation_next +%= 1;

        if (table.generation_next == 0) {
            table.generation_next = 1;
        }

        const slot = &table.slots[index];

        slot.* = Slot{
            .anchor = options.anchor,
            .generation = generation,
            .height = options.height,
            .margin = options.margin,
            .name_len = @intCast(options.name.len),
            .used = true,
            .visible = false,
            .width = options.width,
        };

        @memcpy(slot.name[0..options.name.len], options.name);

        const result = surface_module.pack(index, generation);

        assert(table.resolve(result) != null);

        return result;
    }

    pub fn clear(table: *Table) void {
        table.slots = @splat(.{});

        assert(table.count() == 0);
    }

    pub fn count(table: *const Table) u32 {
        var total: u32 = 0;

        for (table.slots) |slot| {
            if (slot.used) {
                total += 1;
            }
        }

        assert(total <= surface_module.surface_count_max);

        return total;
    }

    pub fn release(table: *Table, surface: Surface) void {
        const slot = table.resolve(surface) orelse return;

        slot.* = Slot{};

        assert(table.resolve(surface) == null);
    }

    pub fn resolve(table: *Table, surface: Surface) ?*Slot {
        const parts = surface_module.unpack(surface);

        if (parts.generation == 0) {
            return null;
        }

        if (parts.index >= surface_module.surface_count_max) {
            return null;
        }

        const slot = &table.slots[parts.index];

        if (!slot.used) {
            return null;
        }

        if (slot.generation != parts.generation) {
            return null;
        }

        return slot;
    }
};

pub const FrameStore = struct {
    pixels: [surface_module.surface_count_max][frame_pixels_max]u32 = @splat(@splat(0)),

    pub fn clear(store: *FrameStore, index: u16) void {
        assert(index < surface_module.surface_count_max);

        @memset(&store.pixels[index], 0);
    }

    pub fn view(store: *FrameStore, index: u16, slot: *const Slot) []u32 {
        assert(index < surface_module.surface_count_max);

        const total = slot.pixel_count();

        assert(total <= frame_pixels_max);

        return store.pixels[index][0..total];
    }
};

pub const frame_pixels_max: u32 = surface_module.width_pixels_max *
    surface_module.height_pixels_max;

pub const ready_yield_max: u32 = 1 << 22;

comptime {
    assert(frame_pixels_max > 0);
    assert(ready_yield_max > 0);
}

pub fn wait_ready(comptime state: type) PlatformError!void {
    var attempts: u32 = 0;

    while (attempts < ready_yield_max) : (attempts += 1) {
        assert(attempts < ready_yield_max);

        if (state.current() != .starting) {
            break;
        }

        std.Thread.yield() catch continue;
    }

    if (state.current() != .running) {
        return error.DisplayUnavailable;
    }
}

pub fn assert_backend(comptime backend: type) void {
    comptime {
        assert_runtime(backend);
        assert_surface(backend);
        assert_events(backend);
    }
}

fn assert_runtime(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "runtime", "backend");

    require_fn(scope, "open", fn () PlatformError!void, "runtime");
    require_fn(scope, "close", fn () void, "runtime");
    require_fn(scope, "is_open", fn () bool, "runtime");
}

fn assert_surface(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "surface", "backend");
    const Created = (CapacityError || PlatformError)!Surface;
    const Fallible = (PlatformError || RequestError)!void;

    require_fn(scope, "create", fn (*const Options) Created, "surface");
    require_fn(scope, "destroy", fn (Surface) void, "surface");
    require_fn(scope, "show", fn (Surface) Fallible, "surface");
    require_fn(scope, "hide", fn (Surface) void, "surface");
    require_fn(scope, "is_visible", fn (Surface) bool, "surface");
    require_fn(scope, "frame", fn (Surface) []u32, "surface");
    require_fn(scope, "present", fn (Surface) Fallible, "surface");
}

fn assert_events(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "events", "backend");

    require_fn(scope, "subscribe", fn (Listener, *anyopaque) void, "events");
    require_fn(scope, "unsubscribe", fn () void, "events");
    require_fn(scope, "is_subscribed", fn () bool, "events");
    require_fn(scope, "poll", fn (*Event.List) u32, "events");
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

const testing = std.testing;

const widget = Options{ .height = 220, .name = "widget", .width = 380 };

test "the table fills to its bound and then reports the overflow" {
    var table = Table{};
    var index: u32 = 0;

    while (index < surface_module.surface_count_max) : (index += 1) {
        _ = try table.acquire(&widget);
    }

    try testing.expectEqual(surface_module.surface_count_max, table.count());
    try testing.expectError(error.SurfacesExhausted, table.acquire(&widget));

    table.clear();

    try testing.expectEqual(@as(u32, 0), table.count());
}

test "a released surface never resolves again" {
    var table = Table{};

    const first = try table.acquire(&widget);

    try testing.expect(table.resolve(first) != null);

    table.release(first);

    try testing.expect(table.resolve(first) == null);

    const second = try table.acquire(&widget);
    const reused = surface_module.unpack(second).index;

    try testing.expectEqual(surface_module.unpack(first).index, reused);
    try testing.expect(first != second);
    try testing.expect(table.resolve(first) == null);
    try testing.expect(table.resolve(second) != null);
}

test "a surface with a zero generation never resolves" {
    var table = Table{};

    _ = try table.acquire(&widget);

    const forged: Surface = @fromBackingInt(0);

    try testing.expect(table.resolve(forged) == null);
}

test "a slot remembers its name and sizes its frame" {
    var table = Table{};

    const surface = try table.acquire(&widget);
    const slot = table.resolve(surface) orelse return error.MissingSlot;

    try testing.expectEqualStrings("widget", slot.get_name());
    try testing.expectEqual(@as(u32, 380 * 220), slot.pixel_count());
}

test "a frame view covers exactly the surface pixels" {
    var store = FrameStore{};

    const slot = Slot{ .height = 220, .used = true, .width = 380 };
    const pixels = store.view(0, &slot);

    try testing.expectEqual(@as(usize, 380 * 220), pixels.len);

    pixels[0] = 0xFFFFFFFF;

    store.clear(0);

    try testing.expectEqual(@as(u32, 0), store.pixels[0][0]);
}
