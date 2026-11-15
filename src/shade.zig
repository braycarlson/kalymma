const std = @import("std");

const platform = @import("platform.zig");

const assert = std.debug.assert;

const Rect = platform.Rect;

pub const Shade = enum(u32) {
    _,

    pub const Options = struct {
        color: u32,
        cursor: Cursor = .crosshair,
        interactive: bool = false,
        rect: Rect,

        pub fn is_valid(options: *const Options) bool {
            options.validate() catch return false;

            return true;
        }

        pub fn validate(options: *const Options) (CapacityError || RequestError)!void {
            try validate_rect(options.rect);
        }
    };
};

pub const Cursor = enum(u8) {
    arrow = 0,
    crosshair = 1,
    move = 2,
    resize_east_west = 3,
    resize_north_south = 4,
    resize_northeast_southwest = 5,
    resize_northwest_southeast = 6,
};

pub const Parts = struct {
    generation: u16,
    index: u16,
};

pub const CapacityError = error{
    ShadeOutOfRange,
    ShadesExhausted,
};

pub const RequestError = error{
    ShadeEmpty,
    ShadeUnknown,
};

pub const coordinate_max: i32 = std.math.maxInt(i16);
pub const coordinate_min: i32 = std.math.minInt(i16);
pub const count_max: u32 = 16;

comptime {
    assert(coordinate_min < 0);
    assert(coordinate_max > 0);
    assert(count_max > 0);
    assert(count_max <= std.math.maxInt(u16));
}

pub fn validate_rect(rect: Rect) (CapacityError || RequestError)!void {
    if (rect.width <= 0) return error.ShadeEmpty;
    if (rect.height <= 0) return error.ShadeEmpty;
    if (rect.x < coordinate_min) return error.ShadeOutOfRange;
    if (rect.y < coordinate_min) return error.ShadeOutOfRange;
    if (rect.x > coordinate_max - rect.width) return error.ShadeOutOfRange;
    if (rect.y > coordinate_max - rect.height) return error.ShadeOutOfRange;
}

pub fn premultiply(color: u32) u32 {
    const alpha: u32 = color >> 24;
    const red = scale(@truncate(color >> 16), alpha);
    const green = scale(@truncate(color >> 8), alpha);
    const blue = scale(@truncate(color), alpha);

    const result = (alpha << 24) | (red << 16) | (green << 8) | blue;

    assert(result >> 24 == alpha);
    assert((result >> 16) & 0xFF <= alpha);

    return result;
}

fn scale(channel: u8, alpha: u32) u32 {
    assert(alpha <= 0xFF);

    const result = @divTrunc(@as(u32, channel) * alpha + 127, 0xFF);

    assert(result <= alpha);

    return result;
}

pub fn pack(index: u16, generation: u16) Shade {
    assert(index < count_max);
    assert(generation > 0);

    const raw = (@as(u32, generation) << 16) | index;
    return @fromBackingInt(raw);
}

pub fn unpack(shade: Shade) Parts {
    const raw = @backingInt(shade);

    const result = Parts{
        .generation = @intCast(raw >> 16),
        .index = @truncate(raw),
    };

    return result;
}

const testing = std.testing;

test Shade {
    const dim = Shade.Options{
        .color = 0x80000000,
        .rect = .{ .height = 1080, .width = 1920, .x = 1920, .y = 0 },
    };

    try dim.validate();

    try testing.expect(!dim.interactive);
}

test CapacityError {
    const wide = Rect{ .height = 10, .width = coordinate_max, .x = 1, .y = 0 };
    const left = Rect{ .height = 10, .width = 10, .x = coordinate_min - 1, .y = 0 };
    const edge = Rect{ .height = 10, .width = 10, .x = coordinate_max - 10, .y = 0 };

    try testing.expectError(error.ShadeOutOfRange, validate_rect(wide));
    try testing.expectError(error.ShadeOutOfRange, validate_rect(left));

    try validate_rect(edge);
}

test RequestError {
    const flat = Rect{ .height = 0, .width = 1920, .x = 0, .y = 0 };
    const inverted = Rect{ .height = 1080, .width = -4, .x = 0, .y = 0 };

    try testing.expectError(error.ShadeEmpty, validate_rect(flat));
    try testing.expectError(error.ShadeEmpty, validate_rect(inverted));
}

test "premultiplying keeps every channel at or below the alpha" {
    try testing.expectEqual(@as(u32, 0x80000000), premultiply(0x80000000));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), premultiply(0xFFFFFFFF));
    try testing.expectEqual(@as(u32, 0x00000000), premultiply(0x00FFFFFF));
    try testing.expectEqual(@as(u32, 0x80800000), premultiply(0x80FF0000));

    var alpha: u32 = 0;

    while (alpha <= 0xFF) : (alpha += 1) {
        const color = premultiply((alpha << 24) | 0x00FFFFFF);

        try testing.expectEqual(alpha, (color >> 16) & 0xFF);
        try testing.expectEqual(alpha, color & 0xFF);
    }
}

test "a packed shade unpacks into the slot and generation it was built from" {
    var generation: u16 = 1;

    while (generation < 512) : (generation += 1) {
        var index: u16 = 0;

        while (index < count_max) : (index += 1) {
            const parts = unpack(pack(index, generation));

            try testing.expectEqual(index, parts.index);
            try testing.expectEqual(generation, parts.generation);
        }
    }
}
