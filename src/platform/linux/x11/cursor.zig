const std = @import("std");

const shade_module = @import("../../../shade.zig");
const sys = @import("../sys.zig");

const assert = std.debug.assert;

const Cursor = shade_module.Cursor;

pub const Image = struct {
    height: u16,
    hot_x: u16,
    hot_y: u16,
    width: u16,

    pub fn pixel_count(image: Image) u32 {
        assert(image.width > 0);
        assert(image.height > 0);

        const result = @as(u32, image.width) * image.height;

        assert(result <= image_pixels_max);

        return result;
    }
};

pub const Settings = struct {
    size: u32 = size_default,
    theme: Name = .{},
};

pub const Name = struct {
    bytes: [name_bytes_max]u8 = undefined,
    length: u8 = 0,

    pub fn init(text: []const u8) ?Name {
        assert(text.len <= sys.environ_bytes_max);

        if (text.len == 0) return null;
        if (text.len > name_bytes_max) return null;

        var result = Name{ .length = @intCast(text.len) };

        @memcpy(result.bytes[0..text.len], text);

        assert(std.mem.eql(u8, result.slice(), text));

        return result;
    }

    pub fn slice(name: *const Name) []const u8 {
        assert(name.length <= name_bytes_max);

        return name.bytes[0..name.length];
    }
};

pub const chunk_header_bytes: u32 = 36;
pub const directory_count_max: u32 = 8;
pub const file_header_bytes: u32 = 16;
pub const glyph_count_max: u16 = 154;
pub const image_side_max: u32 = 96;
pub const image_pixels_max: u32 = image_side_max * image_side_max;
pub const image_type: u32 = 0xfffd0002;
pub const index_bytes_max: u32 = 4096;
pub const magic: u32 = 0x72756358;
pub const name_bytes_max: u32 = 64;
pub const path_bytes_max: u32 = 512;
pub const size_default: u32 = 24;
pub const size_max: u32 = 256;
pub const theme_count_max: u32 = 8;
pub const toc_entries_max: u32 = 64;
pub const toc_entry_bytes: u32 = 12;

const directories_default = [_][]const u8{
    "~/.local/share/icons",
    "~/.icons",
    "/usr/share/icons",
    "/usr/share/pixmaps",
};

comptime {
    assert(chunk_header_bytes == 36);
    assert(file_header_bytes == 16);
    assert(toc_entry_bytes == 12);
    assert(image_side_max <= std.math.maxInt(u16));
    assert(directories_default.len <= directory_count_max);
    assert(size_default <= size_max);
    assert(name_bytes_max <= std.math.maxInt(u8));
    assert(toc_entries_max * toc_entry_bytes <= index_bytes_max);
}

const Directories = struct {
    count: u32 = 0,
    paths: [directory_count_max][]const u8 = undefined,
    storage: [path_bytes_max]u8 = undefined,
    used: u32 = 0,

    fn append(list: *Directories, home: ?[]const u8, path: []const u8) void {
        assert(list.count <= directory_count_max);
        assert(list.used <= path_bytes_max);
        assert(path.len <= sys.environ_bytes_max);
        if (home) |value| assert(value.len <= sys.environ_bytes_max);

        if (list.count == directory_count_max) return;
        if (path.len == 0) return;

        const tilde = path[0] == '~';
        const prefix = if (tilde) home orelse return else "";
        const rest = if (tilde) path[1..] else path;
        const length = prefix.len + rest.len;

        if (list.used + length > path_bytes_max) return;

        const target = list.storage[list.used..][0..length];

        @memcpy(target[0..prefix.len], prefix);
        @memcpy(target[prefix.len..], rest);

        list.paths[list.count] = target;
        list.count += 1;
        list.used += @intCast(length);
    }

    fn slice(list: *const Directories) []const []const u8 {
        assert(list.count <= directory_count_max);

        return list.paths[0..list.count];
    }
};

const Themes = struct {
    count: u32 = 0,
    names: [theme_count_max]Name = undefined,

    fn append(list: *Themes, text: []const u8) void {
        assert(list.count <= theme_count_max);
        assert(text.len <= index_bytes_max);

        if (list.count == theme_count_max) return;

        const name = Name.init(text) orelse return;

        for (list.names[0..list.count]) |*known| {
            if (std.mem.eql(u8, known.slice(), text)) return;
        }

        list.names[list.count] = name;
        list.count += 1;
    }
};

pub fn names_of(cursor: Cursor) []const []const u8 {
    const result: []const []const u8 = switch (cursor) {
        .arrow => &.{ "default", "left_ptr", "arrow" },
        .crosshair => &.{ "crosshair", "cross", "tcross" },
        .move => &.{ "fleur", "all-resize", "move", "size_all" },
        .resize_east_west => &.{ "ew-resize", "sb_h_double_arrow", "size_hor", "h_double_arrow" },
        .resize_north_south => &.{ "ns-resize", "sb_v_double_arrow", "size_ver", "v_double_arrow" },
        .resize_northeast_southwest => &.{ "nesw-resize", "size_bdiag", "fd_double_arrow" },
        .resize_northwest_southeast => &.{ "nwse-resize", "size_fdiag", "bd_double_arrow" },
    };

    assert(result.len > 0);

    return result;
}

pub fn glyph_of(cursor: Cursor) u16 {
    const result: u16 = switch (cursor) {
        .arrow => 68,
        .crosshair => 34,
        .move => 52,
        .resize_east_west => 108,
        .resize_north_south => 116,
        .resize_northeast_southwest => 12,
        .resize_northwest_southeast => 14,
    };

    assert(result % 2 == 0);
    assert(result < glyph_count_max);

    return result;
}

pub fn settings_of(environ: *const sys.Environ, resources: []const u8) Settings {
    assert(resources.len <= index_bytes_max);

    var result = Settings{};

    const theme = environ.get("XCURSOR_THEME") orelse resource_of(resources, "Xcursor.theme");
    const size = environ.get("XCURSOR_SIZE") orelse resource_of(resources, "Xcursor.size");

    result.theme = Name.init(theme orelse "default") orelse Name.init("default").?;
    result.size = size_of(size orelse "") orelse size_default;

    assert(result.size > 0);
    assert(result.size <= size_max);

    return result;
}

pub fn resource_of(resources: []const u8, key: []const u8) ?[]const u8 {
    assert(key.len > 0);
    assert(resources.len <= index_bytes_max);

    var lines = std.mem.splitScalar(u8, resources, '\n');
    var visited: u32 = 0;

    while (lines.next()) |line| : (visited += 1) {
        assert(visited <= resources.len);

        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len) continue;
        if (line[key.len] != ':') continue;

        const value = std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
        if (value.len == 0) return null;
        return value;
    }

    return null;
}

pub fn size_of(text: []const u8) ?u32 {
    assert(text.len <= sys.environ_bytes_max);

    if (text.len == 0) return null;
    if (text.len > 4) return null;

    const value = std.fmt.parseInt(u32, text, 10) catch return null;
    if (value == 0) return null;
    if (value > size_max) return null;
    return value;
}

pub fn inherits_of(index: []const u8) ?[]const u8 {
    assert(index.len <= index_bytes_max);

    var lines = std.mem.splitScalar(u8, index, '\n');
    var visited: u32 = 0;

    while (lines.next()) |line| : (visited += 1) {
        assert(visited <= index.len);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "Inherits")) continue;

        const rest = std.mem.trimStart(u8, trimmed["Inherits".len..], " \t");
        if (rest.len == 0) continue;
        if (rest[0] != '=') continue;

        const value = std.mem.trim(u8, rest[1..], " \t");
        if (value.len == 0) return null;
        return value;
    }

    return null;
}

pub fn choose(toc: []const u8, desired: u32) ?u32 {
    assert(toc.len % toc_entry_bytes == 0);
    assert(toc.len <= toc_entries_max * toc_entry_bytes);
    assert(desired > 0);

    var best_distance: u32 = std.math.maxInt(u32);
    var best_position: ?u32 = null;
    var offset: u32 = 0;

    while (offset < toc.len) : (offset += toc_entry_bytes) {
        const kind = std.mem.readInt(u32, toc[offset..][0..4], .little);
        const nominal = std.mem.readInt(u32, toc[offset + 4 ..][0..4], .little);
        const position = std.mem.readInt(u32, toc[offset + 8 ..][0..4], .little);

        if (kind != image_type) continue;
        if (nominal == 0) continue;
        if (nominal > image_side_max) continue;

        const distance = if (nominal > desired) nominal - desired else desired - nominal;

        if (distance < best_distance) {
            best_distance = distance;
            best_position = position;
        }
    }

    return best_position;
}

pub fn parse_chunk(header: *const [chunk_header_bytes]u8) ?Image {
    const size = std.mem.readInt(u32, header[0..4], .little);
    const kind = std.mem.readInt(u32, header[4..8], .little);
    const width = std.mem.readInt(u32, header[16..20], .little);
    const height = std.mem.readInt(u32, header[20..24], .little);
    const hot_x = std.mem.readInt(u32, header[24..28], .little);
    const hot_y = std.mem.readInt(u32, header[28..32], .little);

    if (size != chunk_header_bytes) return null;
    if (kind != image_type) return null;
    if (width == 0) return null;
    if (height == 0) return null;
    if (width > image_side_max) return null;
    if (height > image_side_max) return null;
    if (hot_x >= width) return null;
    if (hot_y >= height) return null;

    const result = Image{
        .height = @intCast(height),
        .hot_x = @intCast(hot_x),
        .hot_y = @intCast(hot_y),
        .width = @intCast(width),
    };

    assert(result.pixel_count() <= image_pixels_max);

    return result;
}

pub fn load(
    environ: *const sys.Environ,
    settings: *const Settings,
    cursor: Cursor,
    pixels: *[image_pixels_max]u32,
) ?Image {
    assert(settings.size > 0);
    assert(settings.theme.length > 0);

    var directories = Directories{};
    var themes = Themes{};

    collect_directories(environ, &directories);
    themes.append(settings.theme.slice());

    var visited: u32 = 0;

    while (visited < themes.count) : (visited += 1) {
        assert(visited < theme_count_max);

        const theme = themes.names[visited].slice();

        if (find(directories.slice(), theme, cursor, settings.size, pixels)) |image| {
            return image;
        }

        extend(directories.slice(), theme, &themes);
    }

    return null;
}

fn collect_directories(environ: *const sys.Environ, directories: *Directories) void {
    assert(directories.count == 0);

    const home = environ.get("HOME");

    if (environ.get("XCURSOR_PATH")) |list| {
        var parts = std.mem.splitScalar(u8, list, ':');
        var visited: u32 = 0;

        while (parts.next()) |part| : (visited += 1) {
            assert(visited <= list.len);

            directories.append(home, part);
        }

        return;
    }

    for (directories_default) |path| {
        directories.append(home, path);
    }
}

fn find(
    directories: []const []const u8,
    theme: []const u8,
    cursor: Cursor,
    desired: u32,
    pixels: *[image_pixels_max]u32,
) ?Image {
    assert(directories.len <= directory_count_max);
    assert(theme.len > 0);
    assert(desired > 0);

    for (names_of(cursor)) |name| {
        for (directories) |directory| {
            var path: [path_bytes_max]u8 = undefined;

            const joined = join(&path, &.{ directory, "/", theme, "/cursors/", name }) orelse {
                continue;
            };

            const fd = sys.open_read(joined.ptr) catch continue;
            defer sys.close(fd);

            const image = read_image(fd, desired, pixels) orelse continue;

            return image;
        }
    }

    return null;
}

fn extend(directories: []const []const u8, theme: []const u8, themes: *Themes) void {
    assert(directories.len <= directory_count_max);
    assert(theme.len > 0);

    var index: [index_bytes_max]u8 = undefined;

    for (directories) |directory| {
        var path: [path_bytes_max]u8 = undefined;

        const joined = join(&path, &.{ directory, "/", theme, "/index.theme" }) orelse continue;
        const fd = sys.open_read(joined.ptr) catch continue;
        defer sys.close(fd);

        const filled = sys.read(fd, &index) catch continue;
        const value = inherits_of(index[0..filled]) orelse return;

        var parents = std.mem.tokenizeAny(u8, value, ",; ");
        var counted: u32 = 0;

        while (parents.next()) |parent| : (counted += 1) {
            assert(counted <= value.len);

            themes.append(parent);
        }

        return;
    }
}

fn read_image(fd: sys.Fd, desired: u32, pixels: *[image_pixels_max]u32) ?Image {
    assert(fd >= 0);
    assert(desired > 0);

    var header: [file_header_bytes]u8 = undefined;

    if (!read_exact(fd, &header, 0)) return null;
    if (std.mem.readInt(u32, header[0..4], .little) != magic) return null;

    const header_size = std.mem.readInt(u32, header[4..8], .little);
    const count = std.mem.readInt(u32, header[12..16], .little);

    if (header_size < file_header_bytes) return null;
    if (count == 0) return null;
    if (count > toc_entries_max) return null;

    var toc: [toc_entries_max * toc_entry_bytes]u8 = undefined;
    const entries = toc[0 .. count * toc_entry_bytes];

    if (!read_exact(fd, entries, header_size)) return null;

    const position = choose(entries, desired) orelse return null;
    var chunk: [chunk_header_bytes]u8 = undefined;

    if (!read_exact(fd, &chunk, position)) return null;

    const image = parse_chunk(&chunk) orelse return null;
    const start = std.math.add(u32, position, chunk_header_bytes) catch return null;
    const target = std.mem.sliceAsBytes(pixels[0..image.pixel_count()]);

    if (!read_exact(fd, target, start)) return null;

    return image;
}

fn read_exact(fd: sys.Fd, buffer: []u8, offset: u32) bool {
    assert(fd >= 0);
    assert(buffer.len > 0);
    assert(@as(u64, offset) + buffer.len <= std.math.maxInt(i64));

    const count = sys.pread(fd, buffer, offset) catch return false;

    return count == buffer.len;
}

fn join(storage: *[path_bytes_max]u8, parts: []const []const u8) ?[:0]const u8 {
    assert(parts.len > 0);

    var length: u32 = 0;

    for (parts) |part| {
        if (length + part.len + 1 > path_bytes_max) return null;

        @memcpy(storage[length..][0..part.len], part);

        length += @intCast(part.len);
    }

    storage[length] = 0;

    const result = storage[0..length :0];

    assert(result.len == length);

    return result;
}

const testing = std.testing;

fn toc_entry(target: []u8, kind: u32, nominal: u32, position: u32) void {
    assert(target.len == toc_entry_bytes);

    std.mem.writeInt(u32, target[0..4], kind, .little);
    std.mem.writeInt(u32, target[4..8], nominal, .little);
    std.mem.writeInt(u32, target[8..12], position, .little);
}

fn chunk_of(width: u32, height: u32, hot_x: u32, hot_y: u32) [chunk_header_bytes]u8 {
    var result: [chunk_header_bytes]u8 = @splat(0);

    std.mem.writeInt(u32, result[0..4], chunk_header_bytes, .little);
    std.mem.writeInt(u32, result[4..8], image_type, .little);
    std.mem.writeInt(u32, result[8..12], width, .little);
    std.mem.writeInt(u32, result[12..16], 1, .little);
    std.mem.writeInt(u32, result[16..20], width, .little);
    std.mem.writeInt(u32, result[20..24], height, .little);
    std.mem.writeInt(u32, result[24..28], hot_x, .little);
    std.mem.writeInt(u32, result[28..32], hot_y, .little);

    return result;
}

test "each cursor has theme names to try and a classic glyph to fall back on" {
    for (std.enums.values(Cursor)) |cursor| {
        const names = names_of(cursor);

        try testing.expect(names.len > 0);
        try testing.expect(glyph_of(cursor) < glyph_count_max);

        for (names) |name| {
            try testing.expect(name.len > 0);
            try testing.expect(name.len <= name_bytes_max);
        }
    }

    try testing.expectEqualStrings("fleur", names_of(.move)[0]);
    try testing.expectEqual(@as(u16, 108), glyph_of(.resize_east_west));
}

test "the resource database names the theme and the size a person chose" {
    const resources = "*customization:\t-color\nXcursor.size:\t24\nXcursor.theme:\tYaru\n" ++
        "Xcursor.themeless:\tno\nXft.dpi:\t96\n";

    try testing.expectEqualStrings("Yaru", resource_of(resources, "Xcursor.theme").?);
    try testing.expectEqualStrings("24", resource_of(resources, "Xcursor.size").?);
    try testing.expect(resource_of(resources, "Xcursor.missing") == null);
    try testing.expect(resource_of("Xcursor.theme:\t\n", "Xcursor.theme") == null);
    try testing.expectEqual(@as(?u32, 24), size_of("24"));
    try testing.expectEqual(@as(?u32, null), size_of("0"));
    try testing.expectEqual(@as(?u32, null), size_of("9999"));
    try testing.expectEqual(@as(?u32, null), size_of("big"));
}

test "a theme index names the themes it inherits from" {
    const index = "[Icon Theme]\nName=Yaru\nComment=Yaru icons\nInherits = Humanity,hicolor\n";

    try testing.expectEqualStrings("Humanity,hicolor", inherits_of(index).?);
    try testing.expect(inherits_of("[Icon Theme]\nName=Plain\n") == null);
    try testing.expect(inherits_of("InheritsNothing=yes\n") == null);

    var themes = Themes{};

    themes.append("Yaru");
    themes.append("Yaru");
    themes.append("Humanity");

    try testing.expectEqual(@as(u32, 2), themes.count);
}

test "the closest size wins and an earlier entry keeps a tie" {
    var toc: [5 * toc_entry_bytes]u8 = undefined;

    toc_entry(toc[0..12], image_type, 32, 1000);
    toc_entry(toc[12..24], 0xfffe0001, 24, 2000);
    toc_entry(toc[24..36], image_type, 48, 3000);
    toc_entry(toc[36..48], image_type, 16, 4000);
    toc_entry(toc[48..60], image_type, 128, 5000);

    try testing.expectEqual(@as(?u32, 1000), choose(&toc, 24));
    try testing.expectEqual(@as(?u32, 3000), choose(&toc, 44));
    try testing.expectEqual(@as(?u32, 4000), choose(&toc, 8));
    try testing.expectEqual(@as(?u32, 3000), choose(&toc, 256));
    try testing.expectEqual(@as(?u32, null), choose(toc[12..24], 24));
}

test "a chunk header is read only when its size and hotspot are sane" {
    const good = parse_chunk(&chunk_of(24, 24, 12, 11)).?;

    try testing.expectEqual(@as(u16, 24), good.width);
    try testing.expectEqual(@as(u16, 11), good.hot_y);
    try testing.expectEqual(@as(u32, 576), good.pixel_count());
    try testing.expect(parse_chunk(&chunk_of(0, 24, 0, 0)) == null);
    try testing.expect(parse_chunk(&chunk_of(24, 24, 24, 0)) == null);
    try testing.expect(parse_chunk(&chunk_of(image_side_max + 1, 8, 0, 0)) == null);

    var wrong = chunk_of(24, 24, 1, 1);

    std.mem.writeInt(u32, wrong[4..8], 0xfffe0001, .little);

    try testing.expect(parse_chunk(&wrong) == null);
}

test "a search path expands the home directory and stays within its storage" {
    var directories = Directories{};

    directories.append("/home/tester", "~/.icons");
    directories.append(null, "~/.local/share/icons");
    directories.append("/home/tester", "/usr/share/icons");
    directories.append("/home/tester", "");

    try testing.expectEqual(@as(u32, 2), directories.count);
    try testing.expectEqualStrings("/home/tester/.icons", directories.slice()[0]);
    try testing.expectEqualStrings("/usr/share/icons", directories.slice()[1]);

    var path: [path_bytes_max]u8 = undefined;
    const joined = join(&path, &.{ "/usr/share/icons", "/", "Yaru", "/cursors/", "fleur" }).?;

    try testing.expectEqualStrings("/usr/share/icons/Yaru/cursors/fleur", joined);

    const long: [path_bytes_max]u8 = @splat('a');

    try testing.expect(join(&path, &.{&long}) == null);
}
