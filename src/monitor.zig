const std = @import("std");

const platform = @import("platform.zig");

const assert = std.debug.assert;

const Rect = platform.Rect;

pub const Monitor = struct {
    name: [name_bytes_max]u8 = @splat(0),
    name_len: u8 = 0,
    primary: bool = false,
    rect: Rect = .{},

    pub const List = struct {
        count: u32,
        items: [count_max]Monitor,

        pub fn init() List {
            const result = List{ .count = 0, .items = @splat(.{}) };

            assert(result.count == 0);

            return result;
        }

        pub fn append(monitors: *List, monitor: Monitor) void {
            assert(monitors.count < count_max);
            assert(monitor.name_len <= name_bytes_max);

            monitors.items[monitors.count] = monitor;
            monitors.count += 1;

            assert(monitors.count <= count_max);
        }

        pub fn clear(monitors: *List) void {
            monitors.count = 0;

            assert(monitors.slice().len == 0);
        }

        pub fn eql(monitors: *const List, other: *const List) bool {
            assert(monitors.count <= count_max);
            assert(other.count <= count_max);

            if (monitors.count != other.count) {
                return false;
            }

            for (monitors.slice(), other.slice()) |*monitor, *against| {
                if (!monitor.eql(against)) {
                    return false;
                }
            }

            return true;
        }

        pub fn is_full(monitors: *const List) bool {
            assert(monitors.count <= count_max);

            return monitors.count == count_max;
        }

        pub fn slice(monitors: *const List) []const Monitor {
            assert(monitors.count <= count_max);

            return monitors.items[0..monitors.count];
        }
    };

    pub fn init(name: []const u8, rect: Rect) Monitor {
        const length = fitted_length(name);

        var result = Monitor{ .name_len = @intCast(length), .rect = rect };

        @memcpy(result.name[0..length], name[0..length]);

        assert(result.name_len <= name_bytes_max);
        if (is_utf8(name)) assert(is_utf8(result.get_name()));

        return result;
    }

    pub fn eql(monitor: *const Monitor, other: *const Monitor) bool {
        assert(monitor.name_len <= name_bytes_max);
        assert(other.name_len <= name_bytes_max);

        if (!std.mem.eql(u8, monitor.get_name(), other.get_name())) {
            return false;
        }

        if (monitor.primary != other.primary) {
            return false;
        }

        return std.meta.eql(monitor.rect, other.rect);
    }

    pub fn get_name(monitor: *const Monitor) []const u8 {
        assert(monitor.name_len <= name_bytes_max);

        return monitor.name[0..monitor.name_len];
    }
};

pub const count_max: u32 = 8;
pub const name_bytes_max: u32 = 32;

comptime {
    assert(count_max > 0);
    assert(name_bytes_max > 0);
    assert(name_bytes_max <= std.math.maxInt(u8));
}

fn fitted_length(name: []const u8) u32 {
    if (name.len <= name_bytes_max) {
        return @intCast(name.len);
    }

    var result: u32 = name_bytes_max;
    var steps: u32 = 0;

    while (steps < 4) : (steps += 1) {
        if (name[result] & 0xC0 != 0x80) {
            break;
        }

        result -= 1;
    }

    assert(result <= name_bytes_max);
    assert(result + 4 >= name_bytes_max);

    return result;
}

fn is_utf8(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text);
}

const testing = std.testing;

test Monitor {
    const left = Monitor.init("HDMI-5", .{ .height = 1080, .width = 1920, .x = 0, .y = 0 });
    const same = Monitor.init("HDMI-5", .{ .height = 1080, .width = 1920, .x = 0, .y = 0 });
    const moved = Monitor.init("HDMI-5", .{ .height = 1080, .width = 1920, .x = 1920, .y = 0 });

    try testing.expectEqualStrings("HDMI-5", left.get_name());
    try testing.expect(left.eql(&same));
    try testing.expect(!left.eql(&moved));
}

test "a monitor starts secondary and the primary flag takes part in equality" {
    const secondary = Monitor.init("DP-4", .{ .height = 1080, .width = 1920, .x = 1920, .y = 0 });
    var promoted = secondary;
    promoted.primary = true;

    try testing.expect(!secondary.primary);
    try testing.expect(!secondary.eql(&promoted));
    try testing.expect(!promoted.eql(&secondary));
    try testing.expect(promoted.eql(&promoted));

    var first = Monitor.List.init();
    var second = Monitor.List.init();

    first.append(secondary);
    second.append(promoted);

    try testing.expect(!first.eql(&second));
}

test "a list compares by order, name, and rect" {
    var first = Monitor.List.init();
    var second = Monitor.List.init();

    const primary = Monitor.init("DP-4", .{ .height = 1080, .width = 1920, .x = 1920, .y = 0 });
    const side = Monitor.init("DP-5", .{ .height = 1080, .width = 1920, .x = 3840, .y = 0 });

    first.append(primary);
    first.append(side);
    second.append(primary);

    try testing.expect(!first.eql(&second));

    second.append(side);

    try testing.expect(first.eql(&second));

    second.clear();
    second.append(side);
    second.append(primary);

    try testing.expect(!first.eql(&second));
}

test "a list fills to its bound" {
    var monitors = Monitor.List.init();
    var index: u32 = 0;

    while (index < count_max) : (index += 1) {
        monitors.append(Monitor.init("screen", .{ .height = 1, .width = 1 }));
    }

    try testing.expect(monitors.is_full());
    try testing.expectEqual(@as(usize, count_max), monitors.slice().len);
}

test "a long name is cut on a character boundary" {
    const long: [name_bytes_max + 8]u8 = @splat('a');
    const cut = Monitor.init(&long, .{});

    try testing.expectEqual(@as(usize, name_bytes_max), cut.get_name().len);

    var accented: [name_bytes_max + 2]u8 = @splat('b');

    accented[name_bytes_max - 1] = 0xC3;
    accented[name_bytes_max] = 0xA9;

    const kept = Monitor.init(&accented, .{});

    try testing.expectEqual(@as(usize, name_bytes_max - 1), kept.get_name().len);
    try testing.expect(std.unicode.utf8ValidateSlice(kept.get_name()));
}
