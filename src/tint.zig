const std = @import("std");

const assert = std.debug.assert;

pub const Transform = [transform_size][transform_size]f32;

pub const channel_max: f32 = 255;
pub const transform_size: u32 = 5;

comptime {
    assert(channel_max == std.math.maxInt(u8));
    assert(transform_size > 4);
}

pub fn transform(color: u32) Transform {
    const alpha = channel(color >> 24);
    const keep = 1 - alpha;

    var result: Transform = @splat(@splat(0));

    result[0][0] = keep;
    result[1][1] = keep;
    result[2][2] = keep;
    result[3][3] = 1;
    result[4][0] = channel(color >> 16) * alpha;
    result[4][1] = channel(color >> 8) * alpha;
    result[4][2] = channel(color) * alpha;
    result[4][4] = 1;

    assert(keep >= 0);
    assert(keep <= 1);

    return result;
}

fn channel(value: u32) f32 {
    const byte: u8 = @truncate(value);
    const result = @as(f32, @floatFromInt(byte)) / channel_max;

    assert(result >= 0);
    assert(result <= 1);

    return result;
}

const testing = std.testing;

const identity: Transform = .{
    .{ 1, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0 },
    .{ 0, 0, 1, 0, 0 },
    .{ 0, 0, 0, 1, 0 },
    .{ 0, 0, 0, 0, 1 },
};

fn transformed(matrix: *const Transform, pixel: [4]f32) [4]f32 {
    var result: [4]f32 = @splat(0);

    for (0..4) |column| {
        var sum = matrix[4][column];

        for (0..4) |row| {
            sum += pixel[row] * matrix[row][column];
        }

        result[column] = sum;
    }

    return result;
}

test "a transparent tint leaves the screen as it was whatever its color" {
    const colors = [_]u32{ 0x00000000, 0x00FFFFFF, 0x00FF8020 };

    for (colors) |color| {
        try testing.expectEqual(identity, transform(color));
    }
}

test "a tint moves each channel toward its color by its alpha, as a shade of that color would" {
    const colors = [_]u32{ 0x80000000, 0xFF000000, 0x4DFF8020, 0xB3102030, 0xFFFFFFFF };
    const levels = [_]u8{ 0, 17, 128, 200, 255 };

    for (colors) |color| {
        const matrix = transform(color);

        for (levels) |red| {
            for (levels) |green| {
                for (levels) |blue| {
                    try expect_blended(&matrix, color, .{ red, green, blue });
                }
            }
        }
    }
}

fn expect_blended(matrix: *const Transform, color: u32, source: [3]u8) !void {
    const alpha: f32 = @floatFromInt(color >> 24);
    const tint = [3]u8{ @truncate(color >> 16), @truncate(color >> 8), @truncate(color) };

    var pixel: [4]f32 = @splat(1);

    for (0..3) |index| {
        pixel[index] = @as(f32, @floatFromInt(source[index])) / 255;
    }

    const result = transformed(matrix, pixel);

    for (0..3) |index| {
        const before: f32 = @floatFromInt(source[index]);
        const target: f32 = @floatFromInt(tint[index]);
        const expected = (before * (255 - alpha) + target * alpha) / 255;

        try testing.expectApproxEqAbs(expected, result[index] * 255, 0.01);
    }

    try testing.expectApproxEqAbs(@as(f32, 1), result[3], 0.0001);
}
