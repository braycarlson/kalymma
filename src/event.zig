const std = @import("std");

const surface_module = @import("surface.zig");

const assert = std.debug.assert;

const Surface = surface_module.Surface;

pub const Event = struct {
    input: Input,
    surface: Surface,

    pub const Input = union(Input.Kind) {
        pointer_move: Point,
        pointer_down: Point,
        pointer_up: Point,
        pointer_leave: void,
        key_down: Key,
        focus_lost: void,

        pub const Kind = enum(u8) {
            pointer_move = 0,
            pointer_down = 1,
            pointer_up = 2,
            pointer_leave = 3,
            key_down = 4,
            focus_lost = 5,
        };

        pub fn at(input: Input) ?Point {
            const result = switch (input) {
                .pointer_move, .pointer_down, .pointer_up => |point| point,
                else => null,
            };

            return result;
        }
    };

    pub const List = struct {
        count: u32,
        items: [event_count_max]Event,

        pub fn init() List {
            const result = List{ .count = 0, .items = undefined };

            assert(result.is_empty());

            return result;
        }

        pub fn clear(list: *List) void {
            list.count = 0;

            assert(list.is_empty());
        }

        pub fn is_empty(list: *const List) bool {
            return list.count == 0;
        }

        pub fn slice(list: *const List) []const Event {
            assert(list.count <= event_count_max);

            return list.items[0..list.count];
        }

        fn append(list: *List, event: Event) void {
            assert(list.count < event_count_max);

            list.items[list.count] = event;
            list.count += 1;

            assert(list.count <= event_count_max);
        }
    };
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

    pub fn is_valid(key: Key) bool {
        return @backingInt(key) <= @backingInt(Key.other);
    }
};

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn eql(point: Point, other: Point) bool {
        return point.x == other.x and point.y == other.y;
    }
};

pub const Queue = struct {
    count: u32 = 0,
    drops: u32 = 0,
    head: u32 = 0,
    items: [event_count_max]Event = undefined,

    pub fn push(queue: *Queue, event: Event) void {
        assert(queue.count <= event_count_max);

        if (queue.count == event_count_max) {
            queue.head = (queue.head + 1) % event_count_max;
            queue.count -= 1;
            queue.drops += 1;
        }

        const tail = (queue.head + queue.count) % event_count_max;

        queue.items[tail] = event;
        queue.count += 1;

        assert(queue.count <= event_count_max);
    }

    pub fn drain(queue: *Queue, list: *Event.List) u32 {
        assert(queue.count <= event_count_max);

        list.clear();

        var moved: u32 = 0;

        while (moved < queue.count) : (moved += 1) {
            assert(moved < event_count_max);

            const index = (queue.head + moved) % event_count_max;

            list.append(queue.items[index]);
        }

        queue.head = (queue.head + moved) % event_count_max;
        queue.count -= moved;

        assert(list.count == moved);
        assert(queue.is_empty());

        return moved;
    }

    pub fn clear(queue: *Queue) void {
        queue.count = 0;
        queue.drops = 0;
        queue.head = 0;

        assert(queue.is_empty());
    }

    pub fn is_empty(queue: *const Queue) bool {
        return queue.count == 0;
    }
};

pub const event_count_max: u32 = 64;

comptime {
    assert(event_count_max > 1);
    assert(@typeInfo(Event.Input.Kind).@"enum".field_names.len == 6);
}

const testing = std.testing;

test Event {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(0, 1);

    queue.push(.{ .input = .{ .pointer_move = .{ .x = 12, .y = 34 } }, .surface = surface });
    queue.push(.{ .input = .{ .key_down = .escape }, .surface = surface });

    try testing.expectEqual(@as(u32, 2), queue.drain(&list));

    const events = list.slice();

    try testing.expectEqual(Event.Input.Kind.pointer_move, std.meta.activeTag(events[0].input));
    try testing.expect(events[0].input.at().?.eql(.{ .x = 12, .y = 34 }));
    try testing.expectEqual(Key.escape, events[1].input.key_down);
    try testing.expectEqual(surface, events[1].surface);
}

test Key {
    try testing.expect(Key.escape.is_valid());
    try testing.expect(Key.other.is_valid());
}

test Point {
    const point = Point{ .x = 3, .y = 4 };

    try testing.expect(point.eql(.{ .x = 3, .y = 4 }));
    try testing.expect(!point.eql(.{ .x = 4, .y = 3 }));
}

test "only pointer events carry a position" {
    const moved = Event.Input{ .pointer_move = .{ .x = 3, .y = 4 } };
    const pressed = Event.Input{ .key_down = .enter };
    const point = moved.at() orelse return error.MissingPoint;

    try testing.expect(point.eql(.{ .x = 3, .y = 4 }));
    try testing.expect(pressed.at() == null);
}

test "the queue drains in order and stays empty afterwards" {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(0, 1);

    queue.push(.{ .input = .{ .pointer_move = .{ .x = 1, .y = 1 } }, .surface = surface });
    queue.push(.{ .input = .{ .pointer_move = .{ .x = 2, .y = 2 } }, .surface = surface });

    try testing.expectEqual(@as(u32, 2), queue.drain(&list));
    try testing.expectEqual(@as(i32, 1), list.slice()[0].input.pointer_move.x);
    try testing.expectEqual(@as(i32, 2), list.slice()[1].input.pointer_move.x);
    try testing.expectEqual(@as(u32, 0), queue.drain(&list));
}

test "an overflowing queue drops the oldest event and counts the loss" {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(0, 1);

    var index: u32 = 0;

    while (index < event_count_max + 3) : (index += 1) {
        const input = Event.Input{ .pointer_move = .{ .x = @intCast(index), .y = 0 } };

        queue.push(.{ .input = input, .surface = surface });
    }

    try testing.expectEqual(@as(u32, 3), queue.drops);
    try testing.expectEqual(event_count_max, queue.drain(&list));
    try testing.expectEqual(@as(i32, 3), list.slice()[0].input.pointer_move.x);
}

test "the queue keeps wrapping after a drain" {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(0, 1);

    var index: u32 = 0;

    while (index < event_count_max) : (index += 1) {
        const input = Event.Input{ .pointer_move = .{ .x = @intCast(index), .y = 0 } };

        queue.push(.{ .input = input, .surface = surface });
    }

    _ = queue.drain(&list);

    queue.push(.{ .input = .{ .key_down = .escape }, .surface = surface });

    try testing.expectEqual(@as(u32, 1), queue.drain(&list));
    try testing.expectEqual(Key.escape, list.slice()[0].input.key_down);
}
