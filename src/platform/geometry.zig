const std = @import("std");

const contract = @import("contract.zig");

const assert = std.debug.assert;

const Anchor = contract.Anchor;
const Point = contract.Point;

pub const Rect = struct {
    height: i32 = 0,
    width: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

pub fn anchor_point(work: Rect, width: i32, height: i32, margin: i32, anchor: Anchor) Point {
    assert(width > 0);
    assert(height > 0);
    assert(margin >= 0);

    var result = Point{};

    switch (anchor) {
        .bottom_right => {
            result.x = work.x + work.width - width - margin;
            result.y = work.y + work.height - height - margin;
        },
        .top_right => {
            result.x = work.x + work.width - width - margin;
            result.y = work.y + margin;
        },
        .center => {
            result.x = work.x + @divTrunc(work.width - width, 2);
            result.y = work.y + @divTrunc(work.height - height, 2);
        },
    }

    if (result.x < work.x) {
        result.x = work.x;
    }

    if (result.y < work.y) {
        result.y = work.y;
    }

    return result;
}

const testing = std.testing;

test "every anchor places the surface inside the work area" {
    const work = Rect{ .height = 1040, .width = 1920, .x = 0, .y = 0 };

    const bottom = anchor_point(work, 380, 220, 12, .bottom_right);
    const top = anchor_point(work, 380, 220, 12, .top_right);
    const middle = anchor_point(work, 380, 220, 12, .center);

    try testing.expectEqual(@as(i32, 1528), bottom.x);
    try testing.expectEqual(@as(i32, 808), bottom.y);
    try testing.expectEqual(@as(i32, 1528), top.x);
    try testing.expectEqual(@as(i32, 12), top.y);
    try testing.expectEqual(@as(i32, 770), middle.x);
    try testing.expectEqual(@as(i32, 410), middle.y);
}

test "a work area smaller than the surface clamps to its origin" {
    const work = Rect{ .height = 100, .width = 200, .x = 100, .y = 50 };

    const placed = anchor_point(work, 380, 220, 12, .bottom_right);

    try testing.expectEqual(@as(i32, 100), placed.x);
    try testing.expectEqual(@as(i32, 50), placed.y);
}

test "an origin offset work area anchors relative to that origin" {
    const work = Rect{ .height = 1000, .width = 1600, .x = 1920, .y = 100 };

    const bottom = anchor_point(work, 380, 220, 12, .bottom_right);

    try testing.expectEqual(@as(i32, 3128), bottom.x);
    try testing.expectEqual(@as(i32, 868), bottom.y);
}
