const std = @import("std");

const auth = @import("auth.zig");
const contract = @import("../../contract.zig");
const geometry = @import("../../geometry.zig");
const protocol = @import("protocol.zig");
const seam = @import("../seam.zig");
const state = @import("../state.zig");
const sys = @import("../sys.zig");

const assert = std.debug.assert;

const Rect = geometry.Rect;
const Slot = contract.Slot;

pub const Error = seam.Error;

pub const chunk_bytes_max: u32 = 64 * 1024;
pub const message_attempts_max: u32 = 4096;
pub const put_image_header: u32 = 24;
pub const request_bytes_max: u32 = 512;
pub const setup_bytes_max: u32 = 32 * 1024;
pub const socket_path_bytes_max: u32 = 128;
pub const surfaces_max: u32 = contract.surfaces_max;

comptime {
    assert(chunk_bytes_max > request_bytes_max);
    assert(put_image_header == 24);
    assert(message_attempts_max > 0);
    assert(setup_bytes_max > 0);
    assert(socket_path_bytes_max > 0);
}

const Surface = struct {
    gc: u32 = 0,
    height: u32 = 0,
    mapped: bool = false,
    width: u32 = 0,
    window: u32 = 0,
};

var argb_depth: u8 = 0;
var argb_visual: u32 = 0;
var chunk: [chunk_bytes_max]u8 = @splat(0);
var colormap: u32 = 0;
var fatal: bool = false;
var next_resource: u32 = 1;
var request_bytes_limit: u32 = 0;
var resource_base: u32 = 0;
var resource_mask: u32 = 0;
var root: u32 = 0;
var root_depth: u8 = 0;
var root_visual: u32 = 0;
var screen_height: u16 = 0;
var screen_width: u16 = 0;
var setup: [setup_bytes_max]u8 = @splat(0);
var socket: sys.Fd = -1;
var surfaces: [surfaces_max]Surface = @splat(.{});
var work_area: Rect = .{};

pub fn open() Error!void {
    var path_storage: [socket_path_bytes_max]u8 = undefined;

    const display = sys.getenv("DISPLAY") orelse {
        return Error.Unavailable;
    };

    const number = display_number(display);
    const path = try resolve_socket(&path_storage, display);

    socket = sys.unix_socket() catch {
        return Error.Unavailable;
    };

    errdefer close();

    sys.connect_path(socket, path) catch {
        return Error.Unavailable;
    };

    fatal = false;
    next_resource = 1;

    try handshake(number);
    try select_visual();

    load_work_area();
}

pub fn close() void {
    var index: u16 = 0;

    while (index < surfaces_max) : (index += 1) {
        assert(index < surfaces_max);

        destroy(index);
    }

    if (socket >= 0) {
        sys.shutdown(socket);
        sys.close(socket);
    }

    argb_depth = 0;
    argb_visual = 0;
    colormap = 0;
    fatal = false;
    next_resource = 1;
    request_bytes_limit = 0;
    resource_base = 0;
    resource_mask = 0;
    root = 0;
    root_depth = 0;
    root_visual = 0;
    screen_height = 0;
    screen_width = 0;
    socket = -1;
    work_area = .{};

    assert(socket < 0);
}

pub fn descriptor() sys.Fd {
    return socket;
}

pub fn is_live() bool {
    return socket >= 0 and !fatal;
}

pub fn create(index: u16, slot: *const Slot) Error!void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (entry.window != 0) {
        return;
    }

    entry.height = slot.height * slot.scale;
    entry.width = slot.width * slot.scale;
    entry.window = allocate();
    entry.gc = allocate();

    try create_window(entry);
    try create_gc(entry);
}

pub fn destroy(index: u16) void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    hide(index);

    if (entry.gc != 0) {
        free_gc(entry.gc) catch {
            fatal = true;
        };
    }

    if (entry.window != 0) {
        destroy_window(entry.window) catch {
            fatal = true;
        };
    }

    entry.* = .{};

    assert(entry.window == 0);
}

pub fn show(index: u16, slot: *const Slot) Error!void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (entry.window == 0) {
        return Error.Failed;
    }

    if (entry.mapped) {
        return;
    }

    const placed = protocol.anchor_point(
        work_area,
        @intCast(entry.width),
        @intCast(entry.height),
        @intCast(slot.margin),
        slot.anchor,
    );

    try configure(entry.window, placed);
    try map_window(entry.window);
    try configure_stack(entry.window);
    try set_focus(entry.window);

    entry.mapped = true;

    assert(entry.mapped);
}

pub fn hide(index: u16) void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (!entry.mapped) {
        return;
    }

    entry.mapped = false;

    unmap_window(entry.window) catch {
        fatal = true;
    };

    assert(!entry.mapped);
}

pub fn is_mapped(index: u16) bool {
    assert(index < surfaces_max);

    return surfaces[index].mapped;
}

pub fn present(index: u16, slot: *const Slot, pixels: []const u32) Error!void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (!entry.mapped) {
        return;
    }

    const stride = entry.width * 4;
    const bytes = std.mem.sliceAsBytes(pixels);

    if (stride == 0 or bytes.len < stride * entry.height) {
        return Error.Failed;
    }

    _ = slot;

    const rows_per_chunk = rows_of(stride);

    var row: u32 = 0;

    while (row < entry.height) : (row += rows_per_chunk) {
        assert(rows_per_chunk > 0);

        const remaining = entry.height - row;
        const rows = @min(rows_per_chunk, remaining);

        try put_image(entry, row, rows, bytes[row * stride ..][0 .. rows * stride]);
    }
}

fn rows_of(stride: u32) u32 {
    assert(stride > 0);

    const limit = if (request_bytes_limit == 0) chunk_bytes_max else request_bytes_limit;
    const ceiling = @min(chunk_bytes_max, limit);

    if (ceiling <= request_bytes_max) {
        return 1;
    }

    const result = @max((ceiling - request_bytes_max) / stride, 1);

    assert(result > 0);

    return result;
}

pub fn pump() void {
    if (socket < 0) {
        return;
    }

    var header: [protocol.event_bytes]u8 = undefined;

    const count = sys.recv_discarding_fds(socket, &header) catch |err| {
        if (err == sys.Error.WouldBlock) {
            return;
        }

        fatal = true;

        return;
    };

    if (count < protocol.event_bytes) {
        fatal = true;

        return;
    }

    dispatch(&header);
}

fn dispatch(header: *const [protocol.event_bytes]u8) void {
    const kind = header[0] & 0x7F;

    if (kind == protocol.reply_error) {
        fatal = true;

        return;
    }

    if (kind == protocol.reply_normal) {
        return;
    }

    const window = std.mem.readInt(u32, header[8..12], .little);
    const index = index_of(window) orelse return;

    const x: i16 = @bitCast(std.mem.readInt(u16, header[24..26], .little));
    const y: i16 = @bitCast(std.mem.readInt(u16, header[26..28], .little));

    const point = contract.Point{ .x = x, .y = y };

    switch (kind) {
        protocol.event_key_press => {
            state.publish(index, .{ .key_down = protocol.to_key(header[1]) });
        },
        protocol.event_button_press => {
            if (header[1] == protocol.button_left) {
                state.publish(index, .{ .pointer_down = point });
            }
        },
        protocol.event_button_release => {
            if (header[1] == protocol.button_left) {
                state.publish(index, .{ .pointer_up = point });
            }
        },
        protocol.event_motion_notify => {
            state.publish(index, .{ .pointer_move = point });
        },
        protocol.event_leave_notify => {
            state.publish(index, .{ .pointer_leave = {} });
        },
        protocol.event_focus_out => {
            state.publish(index, .{ .focus_lost = {} });
        },
        else => {},
    }
}

fn index_of(window: u32) ?u16 {
    var index: u16 = 0;

    while (index < surfaces_max) : (index += 1) {
        assert(index < surfaces_max);

        if (surfaces[index].window != 0 and surfaces[index].window == window) return index;
    }

    return null;
}

fn handshake(number: []const u8) Error!void {
    const cookie = auth.load(number);

    const name: []const u8 = if (cookie == null) "" else protocol.auth_name;
    const data: []const u8 = if (cookie) |value| value.slice() else "";

    var request: [request_bytes_max]u8 = @splat(0);

    request[0] = protocol.byte_order_little;

    std.mem.writeInt(u16, request[2..4], protocol.protocol_major, .little);
    std.mem.writeInt(u16, request[4..6], protocol.protocol_minor, .little);
    std.mem.writeInt(u16, request[6..8], @intCast(name.len), .little);
    std.mem.writeInt(u16, request[8..10], @intCast(data.len), .little);

    var offset: u32 = 12;

    if (name.len + data.len + offset > request_bytes_max) {
        return Error.Failed;
    }

    @memcpy(request[offset..][0..name.len], name);

    offset += protocol.pad(@intCast(name.len));

    @memcpy(request[offset..][0..data.len], data);

    offset += protocol.pad(@intCast(data.len));

    sys.write_all(socket, request[0..offset]) catch {
        return Error.Unavailable;
    };

    try read_setup();
}

fn read_setup() Error!void {
    var header: [8]u8 = undefined;

    sys.read_all(socket, &header) catch {
        return Error.Unavailable;
    };

    if (header[0] != protocol.setup_success) {
        return Error.Unavailable;
    }

    const words = std.mem.readInt(u16, header[6..8], .little);
    const length = @as(u32, words) * 4;

    if (length == 0 or length > setup_bytes_max) {
        return Error.Unavailable;
    }

    sys.read_all(socket, setup[0..length]) catch {
        return Error.Unavailable;
    };

    try parse_setup(setup[0..length]);
}

fn parse_setup(bytes: []const u8) Error!void {
    if (bytes.len < 32) {
        return Error.Unavailable;
    }

    resource_base = std.mem.readInt(u32, bytes[4..8], .little);
    resource_mask = std.mem.readInt(u32, bytes[8..12], .little);

    const vendor_len = std.mem.readInt(u16, bytes[16..18], .little);
    const max_request = std.mem.readInt(u16, bytes[18..20], .little);
    const screen_count = bytes[20];
    const format_count = bytes[21];
    const image_order = bytes[22];

    request_bytes_limit = @as(u32, max_request) * 4;

    if (image_order != 0) {
        return Error.Unavailable;
    }

    if (screen_count == 0) {
        return Error.Unavailable;
    }

    var offset: u32 = 32 + protocol.pad(vendor_len) + @as(u32, format_count) * 8;

    if (offset + 40 > bytes.len) {
        return Error.Unavailable;
    }

    root = std.mem.readInt(u32, bytes[offset..][0..4], .little);
    screen_width = std.mem.readInt(u16, bytes[offset + 20 ..][0..2], .little);
    screen_height = std.mem.readInt(u16, bytes[offset + 22 ..][0..2], .little);
    root_visual = std.mem.readInt(u32, bytes[offset + 32 ..][0..4], .little);
    root_depth = bytes[offset + 38];

    const depth_count = bytes[offset + 39];

    offset += 40;

    find_argb_visual(bytes, offset, depth_count);

    work_area = .{ .height = screen_height, .width = screen_width };

    if (root == 0 or request_bytes_limit == 0) {
        return Error.Unavailable;
    }
}

fn find_argb_visual(bytes: []const u8, start: u32, depth_count: u8) void {
    var offset = start;
    var depth_index: u32 = 0;

    while (depth_index < depth_count) : (depth_index += 1) {
        if (offset + 8 > bytes.len) {
            return;
        }

        const depth = bytes[offset];
        const visual_count = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);

        offset += 8;

        var visual_index: u32 = 0;

        while (visual_index < visual_count) : (visual_index += 1) {
            if (offset + 24 > bytes.len) {
                return;
            }

            const identifier = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            const class = bytes[offset + 4];

            if (depth == 32 and class == protocol.class_true_color and argb_visual == 0) {
                argb_visual = identifier;
                argb_depth = depth;
            }

            offset += 24;
        }
    }
}

fn select_visual() Error!void {
    if (argb_visual == 0) {
        argb_visual = root_visual;
        argb_depth = root_depth;

        return;
    }

    colormap = allocate();

    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_create_colormap;
    request[1] = protocol.colormap_alloc_none;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], colormap, .little);
    std.mem.writeInt(u32, request[8..12], root, .little);
    std.mem.writeInt(u32, request[12..16], argb_visual, .little);

    try send(&request);
}

fn create_window(entry: *Surface) Error!void {
    const uses_colormap = colormap != 0;

    var mask: u32 = protocol.attribute_back_pixel | protocol.attribute_border_pixel |
        protocol.attribute_override_redirect | protocol.attribute_event_mask;

    if (uses_colormap) {
        mask |= protocol.attribute_colormap;
    }

    const values: u32 = if (uses_colormap) 5 else 4;
    const length: u16 = @intCast(8 + values);

    var request: [request_bytes_max]u8 = @splat(0);

    request[0] = protocol.opcode_create_window;
    request[1] = argb_depth;

    std.mem.writeInt(u16, request[2..4], length, .little);
    std.mem.writeInt(u32, request[4..8], entry.window, .little);
    std.mem.writeInt(u32, request[8..12], root, .little);
    std.mem.writeInt(u16, request[12..14], 0, .little);
    std.mem.writeInt(u16, request[14..16], 0, .little);
    std.mem.writeInt(u16, request[16..18], @intCast(entry.width), .little);
    std.mem.writeInt(u16, request[18..20], @intCast(entry.height), .little);
    std.mem.writeInt(u16, request[20..22], 0, .little);
    std.mem.writeInt(u16, request[22..24], protocol.class_input_output, .little);
    std.mem.writeInt(u32, request[24..28], argb_visual, .little);
    std.mem.writeInt(u32, request[28..32], mask, .little);
    std.mem.writeInt(u32, request[32..36], 0, .little);
    std.mem.writeInt(u32, request[36..40], 0, .little);
    std.mem.writeInt(u32, request[40..44], 1, .little);
    std.mem.writeInt(u32, request[44..48], event_mask(), .little);

    if (uses_colormap) {
        std.mem.writeInt(u32, request[48..52], colormap, .little);
    }

    try send(request[0 .. @as(u32, length) * 4]);
}

fn event_mask() u32 {
    const result = protocol.mask_key_press | protocol.mask_button_press |
        protocol.mask_button_release | protocol.mask_leave_window |
        protocol.mask_pointer_motion | protocol.mask_exposure | protocol.mask_focus_change;

    assert(result != 0);

    return result;
}

fn create_gc(entry: *Surface) Error!void {
    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_create_gc;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], entry.gc, .little);
    std.mem.writeInt(u32, request[8..12], entry.window, .little);
    std.mem.writeInt(u32, request[12..16], 0, .little);

    try send(&request);
}

fn free_gc(gc: u32) Error!void {
    var request: [8]u8 = @splat(0);

    request[0] = protocol.opcode_free_gc;

    std.mem.writeInt(u16, request[2..4], 2, .little);
    std.mem.writeInt(u32, request[4..8], gc, .little);

    try send(&request);
}

fn destroy_window(window: u32) Error!void {
    try simple(protocol.opcode_destroy_window, window);
}

fn map_window(window: u32) Error!void {
    try simple(protocol.opcode_map_window, window);
}

fn unmap_window(window: u32) Error!void {
    try simple(protocol.opcode_unmap_window, window);
}

fn simple(opcode: u8, window: u32) Error!void {
    var request: [8]u8 = @splat(0);

    request[0] = opcode;

    std.mem.writeInt(u16, request[2..4], 2, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);

    try send(&request);
}

fn configure(window: u32, placed: Rect) Error!void {
    var request: [28]u8 = @splat(0);

    const mask = protocol.configure_x | protocol.configure_y |
        protocol.configure_width | protocol.configure_height;

    request[0] = protocol.opcode_configure_window;

    std.mem.writeInt(u16, request[2..4], 7, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u16, request[8..10], mask, .little);
    std.mem.writeInt(u32, request[12..16], @bitCast(placed.x), .little);
    std.mem.writeInt(u32, request[16..20], @bitCast(placed.y), .little);
    std.mem.writeInt(u32, request[20..24], @intCast(placed.width), .little);
    std.mem.writeInt(u32, request[24..28], @intCast(placed.height), .little);

    try send(&request);
}

fn configure_stack(window: u32) Error!void {
    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_configure_window;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u16, request[8..10], protocol.configure_stack_mode, .little);
    std.mem.writeInt(u32, request[12..16], protocol.stack_above, .little);

    try send(&request);
}

fn set_focus(window: u32) Error!void {
    var request: [12]u8 = @splat(0);

    request[0] = protocol.opcode_set_input_focus;
    request[1] = protocol.revert_to_parent;

    std.mem.writeInt(u16, request[2..4], 3, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], 0, .little);

    try send(&request);
}

fn put_image(entry: *const Surface, row: u32, rows: u32, bytes: []const u8) Error!void {
    assert(rows > 0);

    const padded = protocol.pad(@intCast(bytes.len));
    const total = put_image_header + padded;

    if (total > chunk_bytes_max) {
        return Error.Failed;
    }

    @memset(chunk[0..put_image_header], 0);

    chunk[0] = protocol.opcode_put_image;
    chunk[1] = protocol.format_z_pixmap;

    std.mem.writeInt(u16, chunk[2..4], @intCast(total / 4), .little);
    std.mem.writeInt(u32, chunk[4..8], entry.window, .little);
    std.mem.writeInt(u32, chunk[8..12], entry.gc, .little);
    std.mem.writeInt(u16, chunk[12..14], @intCast(entry.width), .little);
    std.mem.writeInt(u16, chunk[14..16], @intCast(rows), .little);
    std.mem.writeInt(u16, chunk[16..18], 0, .little);
    std.mem.writeInt(u16, chunk[18..20], @intCast(row), .little);

    chunk[20] = 0;
    chunk[21] = argb_depth;

    @memcpy(chunk[put_image_header..][0..bytes.len], bytes);
    @memset(chunk[put_image_header + bytes.len ..][0 .. padded - bytes.len], 0);

    try send(chunk[0..total]);
}

fn load_work_area() void {
    const atom = intern(protocol.workarea_atom) catch {
        return;
    };

    if (atom == 0) {
        return;
    }

    var value: [16]u8 = @splat(0);

    const filled = get_property(root, atom, &value) catch {
        return;
    };

    if (filled < 16) {
        return;
    }

    work_area = .{
        .x = @bitCast(std.mem.readInt(u32, value[0..4], .little)),
        .y = @bitCast(std.mem.readInt(u32, value[4..8], .little)),
        .width = @bitCast(std.mem.readInt(u32, value[8..12], .little)),
        .height = @bitCast(std.mem.readInt(u32, value[12..16], .little)),
    };

    if (work_area.width <= 0 or work_area.height <= 0) {
        work_area = .{ .height = screen_height, .width = screen_width };
    }
}

fn intern(name: []const u8) Error!u32 {
    assert(name.len > 0);

    const padded = protocol.pad(@intCast(name.len));
    const total = 8 + padded;

    if (total > request_bytes_max) {
        return Error.Failed;
    }

    var request: [request_bytes_max]u8 = @splat(0);

    request[0] = protocol.opcode_intern_atom;
    request[1] = 0;

    std.mem.writeInt(u16, request[2..4], @intCast(total / 4), .little);
    std.mem.writeInt(u16, request[4..6], @intCast(name.len), .little);

    @memcpy(request[8..][0..name.len], name);

    try send(request[0..total]);

    var reply: [protocol.event_bytes]u8 = undefined;

    const extra = try wait_reply(&reply);

    _ = extra;

    return std.mem.readInt(u32, reply[8..12], .little);
}

fn get_property(window: u32, property: u32, value: []u8) Error!u32 {
    var request: [24]u8 = @splat(0);

    request[0] = protocol.opcode_get_property;

    std.mem.writeInt(u16, request[2..4], 6, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], property, .little);
    std.mem.writeInt(u32, request[12..16], 0, .little);
    std.mem.writeInt(u32, request[16..20], 0, .little);
    std.mem.writeInt(u32, request[20..24], 4, .little);

    try send(&request);

    var reply: [protocol.event_bytes]u8 = undefined;

    const extra = try wait_reply(&reply);

    if (extra == 0) {
        return 0;
    }

    const wanted = @min(extra, value.len);

    @memcpy(value[0..wanted], chunk[0..wanted]);

    return @intCast(wanted);
}

fn wait_reply(reply: *[protocol.event_bytes]u8) Error!u32 {
    var attempts: u32 = 0;

    while (attempts < message_attempts_max) : (attempts += 1) {
        assert(attempts < message_attempts_max);

        sys.read_all(socket, reply) catch {
            fatal = true;

            return Error.Failed;
        };

        const kind = reply[0] & 0x7F;

        if (kind == protocol.reply_error) {
            return Error.Failed;
        }

        if (kind != protocol.reply_normal) {
            dispatch(reply);

            continue;
        }

        const words = std.mem.readInt(u32, reply[4..8], .little);
        const extra = words * 4;

        if (extra == 0) {
            return 0;
        }

        if (extra > chunk_bytes_max) {
            return Error.Failed;
        }

        sys.read_all(socket, chunk[0..extra]) catch {
            fatal = true;

            return Error.Failed;
        };

        return extra;
    }

    return Error.Failed;
}

fn send(bytes: []const u8) Error!void {
    sys.write_all(socket, bytes) catch {
        fatal = true;

        return Error.Failed;
    };
}

fn allocate() u32 {
    const result = resource_base | (next_resource & resource_mask);

    next_resource += 1;

    assert(next_resource > 1);

    return result;
}

pub fn display_number(display: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return "";

    const tail = display[colon + 1 ..];

    const dot = std.mem.indexOfScalar(u8, tail, '.') orelse return tail;

    return tail[0..dot];
}

pub fn resolve_socket(storage: []u8, display: []const u8) Error![]const u8 {
    assert(storage.len > 0);

    const number = display_number(display);

    if (number.len == 0) {
        return Error.Unavailable;
    }

    const result = std.fmt.bufPrint(storage, "/tmp/.X11-unix/X{s}", .{number}) catch {
        return Error.Unavailable;
    };

    return result;
}

const testing = std.testing;

test "a display string yields the screen number the socket is named after" {
    try testing.expectEqualStrings("0", display_number(":0"));
    try testing.expectEqualStrings("0", display_number(":0.0"));
    try testing.expectEqualStrings("1", display_number("localhost:1.0"));
    try testing.expectEqualStrings("", display_number("nonsense"));
}

test "a socket path is built from the display number" {
    var storage: [socket_path_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("/tmp/.X11-unix/X0", try resolve_socket(&storage, ":0"));
    try testing.expectEqualStrings("/tmp/.X11-unix/X1", try resolve_socket(&storage, ":1.0"));
    try testing.expectError(Error.Unavailable, resolve_socket(&storage, "nonsense"));
}

test "the row budget always advances by at least one row" {
    request_bytes_limit = 262140;

    try testing.expect(rows_of(1520) > 1);
    try testing.expectEqual(@as(u32, 1), rows_of(chunk_bytes_max));

    request_bytes_limit = 0;
}
