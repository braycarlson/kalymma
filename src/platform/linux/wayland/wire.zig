const std = @import("std");

const assert = std.debug.assert;

pub const header_bytes: u16 = 8;
pub const message_bytes_max: u16 = 4096;
pub const string_bytes_max: u16 = 256;

pub const Error = error{
    BufferFull,
    Truncated,
    StringTooLong,
};

pub const Header = struct {
    object: u32,
    opcode: u16,
    size: u16,

    pub fn is_valid(header: *const Header) bool {
        const sized = header.size >= header_bytes;
        const aligned = header.size % 4 == 0;

        return sized and aligned;
    }
};

comptime {
    assert(header_bytes == 8);
    assert(message_bytes_max % 4 == 0);
    assert(string_bytes_max < message_bytes_max);
}

pub const Writer = struct {
    buffer: [message_bytes_max]u8 = @splat(0),
    length: u16 = 0,

    pub fn begin(header: *Writer, object: u32) void {
        assert(object >= 1);

        header.length = 0;

        header.put_u32(object);
        header.put_u32(0);

        assert(header.length == header_bytes);
    }

    pub fn finish(header: *Writer) []const u8 {
        assert(header.length >= header_bytes);
        assert(header.length % 4 == 0);

        return header.buffer[0..header.length];
    }

    pub fn seal(header: *Writer, opcode: u16) void {
        assert(header.length >= header_bytes);

        const word = (@as(u32, header.length) << 16) | opcode;

        std.mem.writeInt(u32, header.buffer[4..8], word, .little);
    }

    pub fn put_u32(header: *Writer, value: u32) void {
        assert(header.length + 4 <= message_bytes_max);

        std.mem.writeInt(u32, header.buffer[header.length..][0..4], value, .little);

        header.length += 4;
    }

    pub fn put_i32(header: *Writer, value: i32) void {
        header.put_u32(@bitCast(value));
    }

    pub fn put_string(header: *Writer, text: []const u8) Error!void {
        if (text.len + 1 > string_bytes_max) {
            return Error.StringTooLong;
        }

        const size: u32 = @intCast(text.len + 1);
        const padded = pad(size);

        if (header.length + 4 + padded > message_bytes_max) {
            return Error.BufferFull;
        }

        header.put_u32(size);

        @memcpy(header.buffer[header.length..][0..text.len], text);

        header.buffer[header.length + text.len] = 0;

        var index: u16 = @intCast(text.len + 1);

        while (index < padded) : (index += 1) {
            header.buffer[header.length + index] = 0;
        }

        header.length += @intCast(padded);

        assert(header.length % 4 == 0);
    }
};

pub const Reader = struct {
    bytes: []const u8,
    offset: u16 = 0,

    pub fn remaining(header: *const Reader) u16 {
        assert(header.offset <= header.bytes.len);

        return @intCast(header.bytes.len - header.offset);
    }

    pub fn read_header(header: *Reader) Error!Header {
        if (header.remaining() < header_bytes) {
            return Error.Truncated;
        }

        const object = try header.read_u32();
        const word = try header.read_u32();

        const result = Header{
            .object = object,
            .opcode = @truncate(word & 0xFFFF),
            .size = @truncate(word >> 16),
        };

        if (!result.is_valid()) {
            return Error.Truncated;
        }

        return result;
    }

    pub fn read_u32(header: *Reader) Error!u32 {
        if (header.remaining() < 4) {
            return Error.Truncated;
        }

        const value = std.mem.readInt(u32, header.bytes[header.offset..][0..4], .little);

        header.offset += 4;

        return value;
    }

    pub fn read_i32(header: *Reader) Error!i32 {
        return @bitCast(try header.read_u32());
    }

    pub fn read_fixed(header: *Reader) Error!i32 {
        const raw = try header.read_i32();

        return raw >> 8;
    }

    pub fn read_string(header: *Reader) Error![]const u8 {
        const size = try header.read_u32();

        if (size == 0) {
            return header.bytes[header.offset..header.offset];
        }

        const padded = pad(size);

        if (header.remaining() < padded) {
            return Error.Truncated;
        }

        const start = header.offset;

        header.offset += @intCast(padded);

        assert(size >= 1);

        return header.bytes[start .. start + size - 1];
    }

    pub fn skip(header: *Reader, size: u16) Error!void {
        if (header.remaining() < size) {
            return Error.Truncated;
        }

        header.offset += size;
    }
};

pub fn pad(size: u32) u32 {
    const result = (size + 3) & ~@as(u32, 3);

    assert(result >= size);
    assert(result % 4 == 0);
    assert(result - size < 4);

    return result;
}

const testing = std.testing;

test "pad rounds up to the next word" {
    try testing.expectEqual(@as(u32, 0), pad(0));
    try testing.expectEqual(@as(u32, 4), pad(1));
    try testing.expectEqual(@as(u32, 4), pad(4));
    try testing.expectEqual(@as(u32, 8), pad(5));
    try testing.expectEqual(@as(u32, 8), pad(8));
}

test "a header round trips through the wire encoding" {
    var writer = Writer{};

    writer.begin(1);
    writer.put_u32(2);
    writer.seal(1);

    const bytes = writer.finish();

    try testing.expectEqual(@as(usize, 12), bytes.len);

    var reader = Reader{ .bytes = bytes };
    const header = try reader.read_header();

    try testing.expectEqual(@as(u32, 1), header.object);
    try testing.expectEqual(@as(u16, 1), header.opcode);
    try testing.expectEqual(@as(u16, 12), header.size);
    try testing.expectEqual(@as(u32, 2), try reader.read_u32());
}

test "strings round trip with their null terminator and padding" {
    var writer = Writer{};

    writer.begin(2);
    try writer.put_string("wl_output");
    writer.seal(0);

    var reader = Reader{ .bytes = writer.finish() };

    _ = try reader.read_header();

    try testing.expectEqualStrings("wl_output", try reader.read_string());
    try testing.expectEqual(@as(u16, 0), reader.remaining());
}

test "an empty string encodes as a single length word" {
    var writer = Writer{};

    writer.begin(2);
    try writer.put_string("");
    writer.seal(0);

    var reader = Reader{ .bytes = writer.finish() };

    _ = try reader.read_header();

    try testing.expectEqualStrings("", try reader.read_string());
}

test "over-long strings are refused before they reach the buffer" {
    var writer = Writer{};

    writer.begin(1);

    const long = "x" ** string_bytes_max;

    try testing.expectError(Error.StringTooLong, writer.put_string(long));
}

test "a truncated buffer reports truncation rather than reading past the end" {
    const bytes = [_]u8{ 1, 0, 0, 0 };

    var reader = Reader{ .bytes = &bytes };

    try testing.expectError(Error.Truncated, reader.read_header());
}

test "fixed point values truncate toward negative infinity" {
    var writer = Writer{};

    writer.begin(1);
    writer.put_i32(256 * 12);
    writer.put_i32(256 * -3 + 128);
    writer.seal(0);

    var reader = Reader{ .bytes = writer.finish() };

    _ = try reader.read_header();

    try testing.expectEqual(@as(i32, 12), try reader.read_fixed());
    try testing.expectEqual(@as(i32, -3), try reader.read_fixed());
}

test "signed integers survive the round trip" {
    var writer = Writer{};

    writer.begin(1);
    writer.put_i32(-1920);
    writer.seal(0);

    var reader = Reader{ .bytes = writer.finish() };

    _ = try reader.read_header();

    try testing.expectEqual(@as(i32, -1920), try reader.read_i32());
}
