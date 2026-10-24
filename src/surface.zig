const std = @import("std");

const platform = @import("platform.zig");

const assert = std.debug.assert;

const backend = platform.backend.surface;

const PlatformError = platform.PlatformError;

pub const Surface = enum(u32) { _ };

pub const Anchor = enum(u8) {
    bottom_right = 0,
    top_right = 1,
    center = 2,

    pub fn is_valid(anchor: Anchor) bool {
        return @backingInt(anchor) <= @backingInt(Anchor.center);
    }
};

pub const Options = struct {
    anchor: Anchor = .bottom_right,
    height: u32,
    margin: u32 = 0,
    name: []const u8,
    width: u32,

    pub fn is_valid(options: *const Options) bool {
        options.validate() catch return false;

        return true;
    }

    pub fn validate(options: *const Options) (CapacityError || RequestError)!void {
        assert(options.anchor.is_valid());

        if (options.name.len == 0) return error.NameEmpty;
        if (options.name.len > name_bytes_max) return error.NameTooLong;
        if (options.width == 0) return error.SurfaceEmpty;
        if (options.height == 0) return error.SurfaceEmpty;
        if (options.width > width_pixels_max) return error.SurfaceTooLarge;
        if (options.height > height_pixels_max) return error.SurfaceTooLarge;
        if (options.margin > margin_pixels_max) return error.MarginTooLarge;
    }
};

pub const Parts = struct {
    generation: u16,
    index: u16,
};

pub const CapacityError = error{
    MarginTooLarge,
    NameTooLong,
    SurfaceTooLarge,
    SurfacesExhausted,
};

pub const RequestError = error{
    NameEmpty,
    SurfaceEmpty,
    SurfaceUnknown,
};

pub const height_pixels_max: u32 = 320;
pub const margin_pixels_max: u32 = 256;
pub const name_bytes_max: u32 = 64;
pub const surface_count_max: u32 = 2;
pub const width_pixels_max: u32 = 512;

comptime {
    assert(height_pixels_max > 0);
    assert(margin_pixels_max > 0);
    assert(name_bytes_max > 0);
    assert(surface_count_max > 0);
    assert(surface_count_max <= std.math.maxInt(u16));
    assert(width_pixels_max > 0);
}

pub fn create(options: Options) (CapacityError || PlatformError || RequestError)!Surface {
    assert(platform.backend.runtime.is_open());

    try options.validate();

    const result = try backend.create(&options);

    assert(!backend.is_visible(result));
    assert(backend.frame(result).len == options.width * options.height);

    return result;
}

pub fn destroy(surface: Surface) void {
    backend.destroy(surface);

    assert(!backend.is_visible(surface));
    assert(backend.frame(surface).len == 0);
}

pub fn frame(surface: Surface) []u32 {
    const result = backend.frame(surface);

    assert(result.len <= width_pixels_max * height_pixels_max);

    return result;
}

pub fn hide(surface: Surface) void {
    backend.hide(surface);

    assert(!backend.is_visible(surface));
}

pub fn is_visible(surface: Surface) bool {
    return backend.is_visible(surface);
}

pub fn present(surface: Surface) (PlatformError || RequestError)!void {
    assert(platform.backend.runtime.is_open());

    try backend.present(surface);
}

pub fn show(surface: Surface) (PlatformError || RequestError)!void {
    assert(platform.backend.runtime.is_open());

    try backend.show(surface);

    assert(backend.is_visible(surface));
}

pub fn pack(index: u16, generation: u16) Surface {
    assert(index < surface_count_max);
    assert(generation > 0);

    const raw = (@as(u32, generation) << 16) | index;
    return @fromBackingInt(raw);
}

pub fn unpack(surface: Surface) Parts {
    const raw = @backingInt(surface);

    const result = Parts{
        .generation = @intCast(raw >> 16),
        .index = @truncate(raw),
    };

    return result;
}

const testing = std.testing;

test Anchor {
    try testing.expect(Anchor.bottom_right.is_valid());
    try testing.expect(Anchor.top_right.is_valid());
    try testing.expect(Anchor.center.is_valid());
}

test Options {
    const widget = Options{ .height = 220, .margin = 12, .name = "widget", .width = 380 };

    try widget.validate();

    try testing.expectEqual(Anchor.bottom_right, widget.anchor);
}

test CapacityError {
    const name: [name_bytes_max + 1]u8 = @splat('n');
    const wide = Options{ .height = 220, .name = "widget", .width = width_pixels_max + 1 };
    const tall = Options{ .height = height_pixels_max + 1, .name = "widget", .width = 380 };
    const named = Options{ .height = 220, .name = &name, .width = 380 };

    const distant = Options{
        .height = 220,
        .margin = margin_pixels_max + 1,
        .name = "widget",
        .width = 380,
    };

    try testing.expectError(error.SurfaceTooLarge, wide.validate());
    try testing.expectError(error.SurfaceTooLarge, tall.validate());
    try testing.expectError(error.NameTooLong, named.validate());
    try testing.expectError(error.MarginTooLarge, distant.validate());
}

test RequestError {
    const nameless = Options{ .height = 220, .name = "", .width = 380 };
    const flat = Options{ .height = 0, .name = "widget", .width = 380 };

    try testing.expectError(error.NameEmpty, nameless.validate());
    try testing.expectError(error.SurfaceEmpty, flat.validate());
}

test "a packed surface unpacks into the slot and generation it was built from" {
    var generation: u16 = 1;

    while (generation < 512) : (generation += 1) {
        var index: u16 = 0;

        while (index < surface_count_max) : (index += 1) {
            const parts = unpack(pack(index, generation));

            try testing.expectEqual(index, parts.index);
            try testing.expectEqual(generation, parts.generation);
        }
    }
}

test "surfaces of different generations in one slot never compare equal" {
    try testing.expect(pack(0, 1) != pack(0, 2));
    try testing.expect(pack(0, 1) != pack(1, 1));
    try testing.expectEqual(pack(1, 7), pack(1, 7));
}
