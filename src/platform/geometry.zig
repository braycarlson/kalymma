const std = @import("std");

const event_module = @import("../event.zig");
const interface = @import("interface.zig");
const surface_module = @import("../surface.zig");

const assert = std.debug.assert;

const Anchor = surface_module.Anchor;
const Point = event_module.Point;
const Slot = interface.Slot;

pub const Rect = struct {
    height: i32 = 0,
    width: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,

    pub fn area(rect: Rect) i64 {
        if (rect.is_empty()) {
            return 0;
        }

        const result = @as(i64, rect.width) * @as(i64, rect.height);

        assert(result > 0);

        return result;
    }

    pub fn encloses(rect: Rect, inner: Rect) bool {
        assert(!inner.is_empty());
        assert(rect.width >= 0);

        if (inner.x < rect.x) return false;
        if (inner.y < rect.y) return false;
        if (inner.right_edge() > rect.right_edge()) return false;
        return inner.bottom_edge() <= rect.bottom_edge();
    }

    pub fn intersect(rect: Rect, other: Rect) Rect {
        const left = @max(@as(i64, rect.x), @as(i64, other.x));
        const top = @max(@as(i64, rect.y), @as(i64, other.y));
        const right = @min(rect.right_edge(), other.right_edge());
        const bottom = @min(rect.bottom_edge(), other.bottom_edge());

        if (right <= left) {
            return .{};
        }

        if (bottom <= top) {
            return .{};
        }

        const result = Rect{
            .height = @intCast(bottom - top),
            .width = @intCast(right - left),
            .x = @intCast(left),
            .y = @intCast(top),
        };

        assert(!result.is_empty());
        assert(result.area() <= @min(rect.area(), other.area()));

        return result;
    }

    pub fn is_empty(rect: Rect) bool {
        if (rect.width <= 0) {
            return true;
        }

        return rect.height <= 0;
    }

    fn bottom_edge(rect: Rect) i64 {
        return @as(i64, rect.y) + @max(rect.height, 0);
    }

    fn right_edge(rect: Rect) i64 {
        return @as(i64, rect.x) + @max(rect.width, 0);
    }
};

pub const Placement = struct {
    anchor: Anchor,
    height: i32,
    margin: i32,
    width: i32,
};

pub fn placement_of(slot: *const Slot) Placement {
    assert(slot.used);
    assert(slot.anchor.is_valid());

    const result = Placement{
        .anchor = slot.anchor,
        .height = @intCast(slot.height),
        .margin = @intCast(slot.margin),
        .width = @intCast(slot.width),
    };

    return result;
}

pub fn anchor_point(work: Rect, placement: Placement) Point {
    assert(placement.width > 0);
    assert(placement.height > 0);
    assert(placement.margin >= 0);

    const width = placement.width;
    const height = placement.height;
    const margin = placement.margin;

    var result = Point{};

    switch (placement.anchor) {
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

test "a rect encloses another exactly when their intersection is the other rect" {
    var prng = std.Random.DefaultPrng.init(0x656e636c6f7365);
    const random = prng.random();
    var enclosed_count: u32 = 0;
    var round: u32 = 0;

    while (round < 4096) : (round += 1) {
        const outer = Rect{
            .height = random.intRangeAtMost(i32, 0, 60),
            .width = random.intRangeAtMost(i32, 0, 60),
            .x = random.intRangeAtMost(i32, -40, 40),
            .y = random.intRangeAtMost(i32, -40, 40),
        };

        const inner = Rect{
            .height = random.intRangeAtMost(i32, 1, 30),
            .width = random.intRangeAtMost(i32, 1, 30),
            .x = random.intRangeAtMost(i32, -40, 60),
            .y = random.intRangeAtMost(i32, -40, 60),
        };

        const expected = std.meta.eql(outer.intersect(inner), inner);

        try testing.expectEqual(expected, outer.encloses(inner));

        if (expected) enclosed_count += 1;
    }

    try testing.expect(enclosed_count > 0);
    try testing.expect(enclosed_count < 4096);
}

fn widget(anchor: Anchor) Placement {
    return .{ .anchor = anchor, .height = 220, .margin = 12, .width = 380 };
}

test "every anchor places the surface inside the work area" {
    const work = Rect{ .height = 1040, .width = 1920, .x = 0, .y = 0 };
    const bottom = anchor_point(work, widget(.bottom_right));
    const top = anchor_point(work, widget(.top_right));
    const middle = anchor_point(work, widget(.center));

    try testing.expectEqual(@as(i32, 1528), bottom.x);
    try testing.expectEqual(@as(i32, 808), bottom.y);
    try testing.expectEqual(@as(i32, 1528), top.x);
    try testing.expectEqual(@as(i32, 12), top.y);
    try testing.expectEqual(@as(i32, 770), middle.x);
    try testing.expectEqual(@as(i32, 410), middle.y);
}

test "a work area smaller than the surface clamps to its origin" {
    const work = Rect{ .height = 100, .width = 200, .x = 100, .y = 50 };
    const placed = anchor_point(work, widget(.bottom_right));

    try testing.expectEqual(@as(i32, 100), placed.x);
    try testing.expectEqual(@as(i32, 50), placed.y);
}

test "an origin offset work area anchors relative to that origin" {
    const work = Rect{ .height = 1000, .width = 1600, .x = 1920, .y = 100 };
    const bottom = anchor_point(work, widget(.bottom_right));

    try testing.expectEqual(@as(i32, 3128), bottom.x);
    try testing.expectEqual(@as(i32, 868), bottom.y);
}

test "a slot carries its anchor, size, and margin into its placement" {
    const slot = Slot{
        .anchor = .top_right,
        .height = 220,
        .margin = 12,
        .used = true,
        .width = 380,
    };

    const placement = placement_of(&slot);

    try testing.expectEqual(Anchor.top_right, placement.anchor);
    try testing.expectEqual(@as(i32, 380), placement.width);
    try testing.expectEqual(@as(i32, 220), placement.height);
    try testing.expectEqual(@as(i32, 12), placement.margin);
}

test "an intersection lies inside both rectangles and is empty when they only touch" {
    const left = Rect{ .height = 1080, .width = 1920, .x = 0, .y = 0 };
    const right = Rect{ .height = 1440, .width = 2560, .x = 1920, .y = -120 };
    const region = Rect{ .height = 400, .width = 600, .x = 1700, .y = 100 };

    try testing.expect(left.intersect(right).is_empty());
    try testing.expectEqual(@as(i64, 0), left.intersect(right).area());

    const on_left = region.intersect(left);
    const on_right = region.intersect(right);
    const left_part = Rect{ .height = 400, .width = 220, .x = 1700, .y = 100 };
    const right_part = Rect{ .height = 400, .width = 380, .x = 1920, .y = 100 };

    try testing.expect(std.meta.eql(left_part, on_left));
    try testing.expect(std.meta.eql(right_part, on_right));
    try testing.expectEqual(region.area(), on_left.area() + on_right.area());
    try testing.expect(std.meta.eql(on_left, left.intersect(region)));
    try testing.expect(std.meta.eql(region, region.intersect(region)));
}

test "an empty or inverted rectangle has no area and intersects nothing" {
    const inverted = Rect{ .height = 10, .width = -10, .x = 5, .y = 5 };
    const screen = Rect{ .height = 1080, .width = 1920 };
    const blank = Rect{};

    try testing.expect(inverted.is_empty());
    try testing.expectEqual(@as(i64, 0), inverted.area());
    try testing.expect(screen.intersect(inverted).is_empty());
    try testing.expect(blank.is_empty());
    try testing.expect(!screen.is_empty());
}
