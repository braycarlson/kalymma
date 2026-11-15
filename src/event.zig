const std = @import("std");

const shade_module = @import("shade.zig");
const surface_module = @import("surface.zig");

const assert = std.debug.assert;

const Shade = shade_module.Shade;
const Surface = surface_module.Surface;

pub const Event = struct {
    input: Input,
    source: Source,

    pub const Input = union(Input.Kind) {
        pointer_move: Point,
        pointer_down: Point,
        pointer_up: Point,
        pointer_leave: void,
        key_down: Key,
        focus_lost: void,
        monitors_changed: void,

        pub const Kind = enum(u8) {
            pointer_move = 0,
            pointer_down = 1,
            pointer_up = 2,
            pointer_leave = 3,
            key_down = 4,
            focus_lost = 5,
            monitors_changed = 6,
        };

        pub fn at(input: Input) ?Point {
            const result = switch (input) {
                .pointer_move, .pointer_down, .pointer_up => |point| point,
                else => null,
            };

            return result;
        }
    };

    pub const Source = union(Source.Kind) {
        display: void,
        shade: Shade,
        surface: Surface,

        pub const Kind = enum(u8) {
            display = 0,
            shade = 1,
            surface = 2,
        };
    };

    pub const List = struct {
        count: u32,
        items: [count_max]Event,

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
            assert(list.count <= count_max);

            return list.items[0..list.count];
        }

        fn append(list: *List, event: Event) void {
            assert(list.count < count_max);

            list.items[list.count] = event;
            list.count += 1;

            assert(list.count <= count_max);
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
    items: [count_max]Event = undefined,

    pub fn push(queue: *Queue, event: Event) void {
        assert(queue.count <= count_max);

        if (queue.count == count_max) {
            queue.head = (queue.head + 1) % count_max;
            queue.count -= 1;
            queue.drops += 1;
        }

        const tail = (queue.head + queue.count) % count_max;

        queue.items[tail] = event;
        queue.count += 1;

        assert(queue.count <= count_max);
    }

    pub fn drain(queue: *Queue, list: *Event.List) u32 {
        assert(queue.count <= count_max);

        list.clear();

        var moved: u32 = 0;

        while (moved < queue.count) : (moved += 1) {
            assert(moved < count_max);

            const index = (queue.head + moved) % count_max;

            list.append(queue.items[index]);
        }

        queue.head = (queue.head + moved) % count_max;
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

pub const count_max: u32 = 64;

comptime {
    assert(count_max > 1);
    assert(@typeInfo(Event.Input.Kind).@"enum".field_names.len == 7);
    assert(@typeInfo(Event.Source.Kind).@"enum".field_names.len == 3);
}

const testing = std.testing;

test Event {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(0, 1);

    const source = Event.Source{ .surface = surface };

    queue.push(.{ .input = .{ .pointer_move = .{ .x = 12, .y = 34 } }, .source = source });
    queue.push(.{ .input = .{ .key_down = .escape }, .source = source });

    try testing.expectEqual(@as(u32, 2), queue.drain(&list));

    const events = list.slice();

    try testing.expectEqual(Event.Input.Kind.pointer_move, std.meta.activeTag(events[0].input));
    try testing.expect(events[0].input.at().?.eql(.{ .x = 12, .y = 34 }));
    try testing.expectEqual(Key.escape, events[1].input.key_down);
    try testing.expectEqual(surface, events[1].source.surface);
}

test "an event names the surface, the shade, or the display it came from" {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(1, 3);
    const shade = shade_module.pack(5, 2);

    const pressed = Event.Input{ .pointer_down = .{ .x = 4, .y = 5 } };

    queue.push(.{ .input = pressed, .source = .{ .shade = shade } });
    queue.push(.{ .input = .{ .monitors_changed = {} }, .source = .{ .display = {} } });
    queue.push(.{ .input = .{ .focus_lost = {} }, .source = .{ .surface = surface } });

    try testing.expectEqual(@as(u32, 3), queue.drain(&list));

    const events = list.slice();

    try testing.expectEqual(shade, events[0].source.shade);
    try testing.expect(events[1].source == .display);
    try testing.expect(events[1].input == .monitors_changed);
    try testing.expect(events[1].input.at() == null);
    try testing.expectEqual(surface, events[2].source.surface);
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

    const source = Event.Source{ .surface = surface };

    queue.push(.{ .input = .{ .pointer_move = .{ .x = 1, .y = 1 } }, .source = source });
    queue.push(.{ .input = .{ .pointer_move = .{ .x = 2, .y = 2 } }, .source = source });

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

    while (index < count_max + 3) : (index += 1) {
        const input = Event.Input{ .pointer_move = .{ .x = @intCast(index), .y = 0 } };

        queue.push(.{ .input = input, .source = .{ .surface = surface } });
    }

    try testing.expectEqual(@as(u32, 3), queue.drops);
    try testing.expectEqual(count_max, queue.drain(&list));
    try testing.expectEqual(@as(i32, 3), list.slice()[0].input.pointer_move.x);
}

test "the queue keeps wrapping after a drain" {
    var queue = Queue{};
    var list = Event.List.init();

    const surface = surface_module.pack(0, 1);

    var index: u32 = 0;

    while (index < count_max) : (index += 1) {
        const input = Event.Input{ .pointer_move = .{ .x = @intCast(index), .y = 0 } };

        queue.push(.{ .input = input, .source = .{ .surface = surface } });
    }

    _ = queue.drain(&list);

    queue.push(.{ .input = .{ .key_down = .escape }, .source = .{ .surface = surface } });

    try testing.expectEqual(@as(u32, 1), queue.drain(&list));
    try testing.expectEqual(Key.escape, list.slice()[0].input.key_down);
}
