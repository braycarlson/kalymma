const std = @import("std");

const event_module = @import("../event.zig");
const geometry = @import("geometry.zig");
const monitor_module = @import("../monitor.zig");
const shade_module = @import("../shade.zig");
const surface_module = @import("../surface.zig");

const assert = std.debug.assert;

const Anchor = surface_module.Anchor;
const CapacityError = surface_module.CapacityError;
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Monitor = monitor_module.Monitor;
const Options = Surface.Options;
const Rect = geometry.Rect;
const RequestError = surface_module.RequestError;
const Shade = shade_module.Shade;
const ShadeCapacityError = shade_module.CapacityError;
const ShadeOptions = Shade.Options;
const ShadeRequestError = shade_module.RequestError;
const Surface = surface_module.Surface;

pub const Listener = *const fn (*anyopaque) void;

pub const PlatformError = error{
    DisplayUnavailable,
    ShadeCreateFailed,
    ShadeUpdateFailed,
    SurfaceCreateFailed,
    SurfacePresentFailed,
    SurfaceShowFailed,
    ThreadSpawnFailed,
    TintFailed,
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
    slots: [surface_module.count_max]Slot = @splat(.{}),

    pub fn acquire(table: *Table, options: *const Options) CapacityError!Surface {
        assert(options.is_valid());

        var index: u16 = 0;

        while (index < surface_module.count_max) : (index += 1) {
            if (!table.slots[index].used) {
                break;
            }
        }

        if (index == surface_module.count_max) {
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

        assert(total <= surface_module.count_max);

        return total;
    }

    pub fn index_of(table: *const Table, surface: Surface) ?u16 {
        const parts = surface_module.unpack(surface);

        if (parts.generation == 0) {
            return null;
        }

        if (parts.index >= surface_module.count_max) {
            return null;
        }

        const slot = &table.slots[parts.index];

        if (!slot.used) {
            return null;
        }

        if (slot.generation != parts.generation) {
            return null;
        }

        return parts.index;
    }

    pub fn is_visible(table: *const Table, surface: Surface) bool {
        const index = table.index_of(surface) orelse return false;

        assert(index < surface_module.count_max);
        assert(table.slots[index].used);

        return table.slots[index].visible;
    }

    pub fn release(table: *Table, surface: Surface) void {
        assert(surface_module.unpack(surface).generation > 0);
        assert(surface_module.unpack(surface).index < surface_module.count_max);

        const slot = table.resolve(surface) orelse return;

        slot.* = Slot{};

        assert(table.resolve(surface) == null);
    }

    pub fn resolve(table: *Table, surface: Surface) ?*Slot {
        const index = table.index_of(surface) orelse return null;

        assert(index < surface_module.count_max);

        return &table.slots[index];
    }
};

pub const ShadeRequest = enum(u8) {
    create = 0,
    destroy = 1,
    fill = 2,
    place = 3,
    cursor = 4,
};

pub const ShadeSlot = struct {
    color: u32 = 0,
    cursor: Cursor = .crosshair,
    generation: u16 = 0,
    interactive: bool = false,
    rect: Rect = .{},
    used: bool = false,
};

pub const ShadeTable = struct {
    generation_next: u16 = 1,
    slots: [shade_module.count_max]ShadeSlot = @splat(.{}),

    pub fn acquire(table: *ShadeTable, options: *const ShadeOptions) ShadeCapacityError!Shade {
        assert(options.is_valid());

        var index: u16 = 0;

        while (index < shade_module.count_max) : (index += 1) {
            if (!table.slots[index].used) {
                break;
            }
        }

        if (index == shade_module.count_max) {
            return error.ShadesExhausted;
        }

        const generation = table.generation_next;

        table.generation_next +%= 1;

        if (table.generation_next == 0) {
            table.generation_next = 1;
        }

        table.slots[index] = ShadeSlot{
            .color = options.color,
            .cursor = options.cursor,
            .generation = generation,
            .interactive = options.interactive,
            .rect = options.rect,
            .used = true,
        };

        const result = shade_module.pack(index, generation);

        assert(table.resolve(result) != null);

        return result;
    }

    pub fn change_cursor(table: *ShadeTable, shade: Shade, cursor: Cursor) ?Cursor {
        assert(shade_module.unpack(shade).generation > 0);
        assert(shade_module.unpack(shade).index < shade_module.count_max);

        const slot = table.resolve(shade) orelse return null;
        const previous = slot.cursor;

        slot.cursor = cursor;

        assert(slot.cursor == cursor);

        return previous;
    }

    pub fn clear(table: *ShadeTable) void {
        table.slots = @splat(.{});

        assert(table.count() == 0);
    }

    pub fn count(table: *const ShadeTable) u32 {
        var total: u32 = 0;

        for (table.slots) |slot| {
            if (slot.used) {
                total += 1;
            }
        }

        assert(total <= shade_module.count_max);

        return total;
    }

    pub fn move(table: *ShadeTable, shade: Shade, rect: Rect) ?Rect {
        assert(shade_module.unpack(shade).generation > 0);
        assert(!rect.is_empty());

        const slot = table.resolve(shade) orelse return null;
        const previous = slot.rect;

        slot.rect = rect;

        assert(std.meta.eql(slot.rect, rect));

        return previous;
    }

    pub fn recolor(table: *ShadeTable, shade: Shade, color: u32) ?u32 {
        assert(shade_module.unpack(shade).generation > 0);
        assert(shade_module.unpack(shade).index < shade_module.count_max);

        const slot = table.resolve(shade) orelse return null;
        const previous = slot.color;

        slot.color = color;

        assert(slot.color == color);

        return previous;
    }

    pub fn release(table: *ShadeTable, shade: Shade) void {
        assert(shade_module.unpack(shade).generation > 0);
        assert(shade_module.unpack(shade).index < shade_module.count_max);

        const slot = table.resolve(shade) orelse return;

        slot.* = ShadeSlot{};

        assert(table.resolve(shade) == null);
    }

    pub fn resolve(table: *ShadeTable, shade: Shade) ?*ShadeSlot {
        const parts = shade_module.unpack(shade);

        if (parts.generation == 0) {
            return null;
        }

        if (parts.index >= shade_module.count_max) {
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
    pixels: [surface_module.count_max][frame_pixels_max]u32 = @splat(@splat(0)),

    pub fn clear(store: *FrameStore, index: u16) void {
        assert(index < surface_module.count_max);

        @memset(&store.pixels[index], 0);
    }

    pub fn view(store: *FrameStore, index: u16, slot: *const Slot) []u32 {
        assert(index < surface_module.count_max);

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

pub fn wait_ready(comptime State: type, state: *const State) PlatformError!void {
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

pub fn assert_backend(comptime Backend: type) void {
    comptime {
        assert_lifetime(Backend);
        assert_events(Backend);
        assert_monitors(Backend);
        assert_shade(Backend);
        assert_surface(Backend);
        assert_tint(Backend);
    }
}

fn assert_lifetime(comptime Backend: type) void {
    require_decl(Backend, "Options");

    if (@TypeOf(Backend.Options) != type) {
        @compileError("kalymma backend " ++ @typeName(Backend) ++ ".Options must be a type");
    }

    require_method(Backend, "init", fn (*Backend, Backend.Options) PlatformError!void);
    require_method(Backend, "deinit", fn (*Backend) void);
}

fn assert_events(comptime Backend: type) void {
    require_method(Backend, "events_is_subscribed", fn (*Backend) bool);
    require_method(Backend, "events_poll", fn (*Backend, *Event.List) u32);
    require_method(Backend, "events_subscribe", fn (*Backend, Listener, *anyopaque) void);
    require_method(Backend, "events_unsubscribe", fn (*Backend) void);
}

fn assert_monitors(comptime Backend: type) void {
    require_method(Backend, "monitors_list", fn (*Backend, *Monitor.List) u32);
}

fn assert_shade(comptime Backend: type) void {
    const Created = (ShadeCapacityError || PlatformError)!Shade;
    const Fallible = (PlatformError || ShadeRequestError)!void;

    require_method(Backend, "shade_create", fn (*Backend, *const ShadeOptions) Created);
    require_method(Backend, "shade_destroy", fn (*Backend, Shade) void);
    require_method(Backend, "shade_fill", fn (*Backend, Shade, u32) Fallible);
    require_method(Backend, "shade_place", fn (*Backend, Shade, Rect) Fallible);
    require_method(Backend, "shade_set_cursor", fn (*Backend, Shade, Cursor) Fallible);
}

fn assert_surface(comptime Backend: type) void {
    const Created = (CapacityError || PlatformError)!Surface;
    const Fallible = (PlatformError || RequestError)!void;

    require_method(Backend, "surface_create", fn (*Backend, *const Options) Created);
    require_method(Backend, "surface_destroy", fn (*Backend, Surface) void);
    require_method(Backend, "surface_frame", fn (*Backend, Surface) []u32);
    require_method(Backend, "surface_hide", fn (*Backend, Surface) void);
    require_method(Backend, "surface_is_visible", fn (*const Backend, Surface) bool);
    require_method(Backend, "surface_present", fn (*Backend, Surface) Fallible);
    require_method(Backend, "surface_show", fn (*Backend, Surface) Fallible);
}

fn assert_tint(comptime Backend: type) void {
    require_method(Backend, "tint_apply", fn (*Backend, u32) PlatformError!void);
    require_method(Backend, "tint_clear", fn (*Backend) void);
    require_method(Backend, "tint_is_supported", fn (*Backend) bool);
}

fn require_decl(comptime Backend: type, comptime name: []const u8) void {
    assert(name.len > 0);
    assert(@typeInfo(Backend) == .@"struct");

    if (!@hasDecl(Backend, name)) {
        @compileError(
            "kalymma backend " ++ @typeName(Backend) ++ " is missing declaration '" ++ name ++ "'",
        );
    }
}

fn require_method(
    comptime Backend: type,
    comptime name: []const u8,
    comptime Signature: type,
) void {
    assert(name.len > 0);
    assert(@typeInfo(Signature) == .@"fn");

    require_decl(Backend, name);

    const Actual = @TypeOf(@field(Backend, name));

    if (Actual != Signature) {
        @compileError(
            "kalymma backend " ++ @typeName(Backend) ++ "." ++ name ++ " has type " ++
                @typeName(Actual) ++ ", expected " ++ @typeName(Signature),
        );
    }
}

const testing = std.testing;

const widget = Options{ .height = 220, .name = "widget", .width = 380 };

test "the table fills to its bound and then reports the overflow" {
    var table = Table{};
    var index: u32 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        _ = try table.acquire(&widget);
    }

    try testing.expectEqual(surface_module.count_max, table.count());
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
    try testing.expectEqual(@as(?u16, null), table.index_of(first));
    try testing.expectEqual(@as(?u16, reused), table.index_of(second));
}

test "a surface with a zero generation never resolves" {
    var table = Table{};

    _ = try table.acquire(&widget);

    const forged: Surface = @fromBackingInt(0);

    try testing.expect(table.resolve(forged) == null);
    try testing.expect(!table.is_visible(forged));
}

test "visibility reads the slot a live surface resolves to and nothing else" {
    var table = Table{};

    const surface = try table.acquire(&widget);

    try testing.expect(!table.is_visible(surface));

    table.resolve(surface).?.visible = true;

    try testing.expect(table.is_visible(surface));

    table.release(surface);

    try testing.expect(!table.is_visible(surface));
}

test "a slot remembers its name and sizes its frame" {
    var table = Table{};

    const surface = try table.acquire(&widget);
    const slot = table.resolve(surface) orelse return error.MissingSlot;

    try testing.expectEqualStrings("widget", slot.get_name());
    try testing.expectEqual(@as(u32, 380 * 220), slot.pixel_count());
}

test "the shade table fills to its bound and never resolves a released shade" {
    var table = ShadeTable{};

    const options = ShadeOptions{
        .color = 0x80000000,
        .rect = .{ .height = 1080, .width = 1920, .x = 0, .y = 0 },
    };

    const first = try table.acquire(&options);
    var index: u32 = 1;

    while (index < shade_module.count_max) : (index += 1) {
        _ = try table.acquire(&options);
    }

    try testing.expectEqual(shade_module.count_max, table.count());
    try testing.expectError(error.ShadesExhausted, table.acquire(&options));

    table.release(first);

    try testing.expect(table.resolve(first) == null);

    const reused = try table.acquire(&options);

    try testing.expectEqual(shade_module.unpack(first).index, shade_module.unpack(reused).index);
    try testing.expect(reused != first);
    try testing.expectEqual(@as(u32, 0x80000000), table.resolve(reused).?.color);

    table.clear();

    try testing.expectEqual(@as(u32, 0), table.count());
}

test "a recolor or move hands back the value it replaced and refuses a stale shade" {
    var table = ShadeTable{};

    const options = ShadeOptions{ .color = 0x80000000, .rect = .{ .height = 10, .width = 10 } };
    const shade = try table.acquire(&options);
    const moved = Rect{ .height = 20, .width = 30, .x = 5, .y = 6 };

    try testing.expectEqual(@as(?u32, 0x80000000), table.recolor(shade, 0x40000000));
    try testing.expectEqual(@as(?u32, 0x40000000), table.recolor(shade, 0x40000000));
    try testing.expect(std.meta.eql(options.rect, table.move(shade, moved).?));
    try testing.expect(std.meta.eql(moved, table.resolve(shade).?.rect));

    table.release(shade);

    try testing.expect(table.recolor(shade, 0) == null);
    try testing.expect(table.move(shade, moved) == null);
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
