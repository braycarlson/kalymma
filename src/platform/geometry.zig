const std = @import("std");

const contract = @import("contract.zig");
const event_module = @import("../event.zig");
const surface_module = @import("../surface.zig");

const assert = std.debug.assert;

const Anchor = surface_module.Anchor;
const Point = event_module.Point;
const Slot = contract.Slot;

pub const Rect = struct {
    height: i32 = 0,
    width: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
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
