const std = @import("std");

const protocol = @import("protocol.zig");
const sys = @import("../sys.zig");

const assert = std.debug.assert;

pub const cookie_bytes_max: u32 = 64;
pub const file_bytes_max: u32 = 16 * 1024;
pub const path_bytes_max: u32 = 256;
pub const entries_max: u32 = 64;

comptime {
    assert(cookie_bytes_max > 0);
    assert(file_bytes_max > 0);
    assert(path_bytes_max > 0);
    assert(entries_max > 0);
}

pub const Cookie = struct {
    bytes: [cookie_bytes_max]u8 = @splat(0),
    len: u16 = 0,

    pub fn slice(cookie: *const Cookie) []const u8 {
        assert(cookie.len <= cookie_bytes_max);

        return cookie.bytes[0..cookie.len];
    }
};

var storage: [file_bytes_max]u8 = @splat(0);

pub fn load(number: []const u8) ?Cookie {
    var path_storage: [path_bytes_max]u8 = undefined;

    const path = resolve(&path_storage) orelse return null;

    const length = read_file(path) orelse return null;

    return find(storage[0..length], number);
}

fn resolve(buffer: []u8) ?[:0]const u8 {
    if (sys.getenv("XAUTHORITY")) |path| {
        return terminate(buffer, path, "");
    }

    const home = sys.getenv("HOME") orelse return null;

    return terminate(buffer, home, "/.Xauthority");
}

fn terminate(buffer: []u8, head: []const u8, tail: []const u8) ?[:0]const u8 {
    const total = head.len + tail.len;

    if (total == 0 or total + 1 > buffer.len) {
        return null;
    }

    @memcpy(buffer[0..head.len], head);
    @memcpy(buffer[head.len..][0..tail.len], tail);

    buffer[total] = 0;

    return buffer[0..total :0];
}

fn read_file(path: [:0]const u8) ?u32 {
    const fd = sys.open_read(path.ptr) catch {
        return null;
    };

    defer sys.close(fd);

    var filled: usize = 0;
    var attempts: u32 = 0;

    while (filled < file_bytes_max and attempts < entries_max) : (attempts += 1) {
        const count = sys.read(fd, storage[filled..]) catch {
            break;
        };

        if (count == 0) {
            break;
        }

        filled += count;
    }

    if (filled == 0) {
        return null;
    }

    return @intCast(filled);
}

pub fn find(bytes: []const u8, number: []const u8) ?Cookie {
    var offset: u32 = 0;
    var visited: u32 = 0;
    var fallback: ?Cookie = null;

    while (visited < entries_max) : (visited += 1) {
        if (offset + 2 > bytes.len) {
            break;
        }

        offset += 2;

        const address = read_block(bytes, &offset) orelse break;
        const display = read_block(bytes, &offset) orelse break;
        const name = read_block(bytes, &offset) orelse break;
        const data = read_block(bytes, &offset) orelse break;

        _ = address;

        if (!std.mem.eql(u8, name, protocol.auth_name)) {
            continue;
        }

        if (data.len > cookie_bytes_max) {
            continue;
        }

        var result = Cookie{ .len = @intCast(data.len) };

        @memcpy(result.bytes[0..data.len], data);

        if (std.mem.eql(u8, display, number)) {
            return result;
        }

        if (fallback == null) {
            fallback = result;
        }
    }

    return fallback;
}

fn read_block(bytes: []const u8, offset: *u32) ?[]const u8 {
    if (offset.* + 2 > bytes.len) {
        return null;
    }

    const length = std.mem.readInt(u16, bytes[offset.*..][0..2], .big);

    offset.* += 2;

    if (offset.* + length > bytes.len) {
        return null;
    }

    const start = offset.*;

    offset.* += length;

    return bytes[start .. start + length];
}

const testing = std.testing;

fn append_block(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    var header: [2]u8 = undefined;

    std.mem.writeInt(u16, &header, @intCast(text.len), .big);

    try list.appendSlice(gpa, &header);
    try list.appendSlice(gpa, text);
}

fn append_entry(
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    number: []const u8,
    name: []const u8,
    data: []const u8,
) !void {
    try list.appendSlice(gpa, &[_]u8{ 0, 1 });
    try append_block(list, gpa, "host");
    try append_block(list, gpa, number);
    try append_block(list, gpa, name);
    try append_block(list, gpa, data);
}

test "the entry whose display number matches wins" {
    const gpa = testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try append_entry(&list, gpa, "0", protocol.auth_name, "first-cookie");
    try append_entry(&list, gpa, "1", protocol.auth_name, "second-cookie");

    const found = find(list.items, "1") orelse return error.MissingCookie;

    try testing.expectEqualStrings("second-cookie", found.slice());
}

test "an entry of another scheme is skipped" {
    const gpa = testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try append_entry(&list, gpa, "0", "XDM-AUTHORIZATION-1", "wrong");
    try append_entry(&list, gpa, "0", protocol.auth_name, "right");

    const found = find(list.items, "0") orelse return error.MissingCookie;

    try testing.expectEqualStrings("right", found.slice());
}

test "a cookie for another display is used when nothing matches" {
    const gpa = testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try append_entry(&list, gpa, "7", protocol.auth_name, "only-cookie");

    const found = find(list.items, "0") orelse return error.MissingCookie;

    try testing.expectEqualStrings("only-cookie", found.slice());
}

test "a truncated file yields nothing rather than reading past the end" {
    const gpa = testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try append_entry(&list, gpa, "0", protocol.auth_name, "cookie");

    const truncated = list.items[0 .. list.items.len - 3];

    try testing.expect(find(truncated, "0") == null);
    try testing.expect(find(&.{}, "0") == null);
}
