const std = @import("std");

const auth = @import("auth.zig");
const cursor_module = @import("cursor.zig");
const Display = @import("../display.zig");
const event_module = @import("../../../event.zig");
const geometry = @import("../../geometry.zig");
const interface = @import("../../interface.zig");
const monitor_module = @import("../../../monitor.zig");
const protocol = @import("protocol.zig");
const shade_module = @import("../../../shade.zig");
const State = @import("../state.zig");
const surface_module = @import("../../../surface.zig");
const sys = @import("../sys.zig");

const assert = std.debug.assert;

const Client = @This();
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Monitor = monitor_module.Monitor;
const Rect = geometry.Rect;
const ShadeSlot = interface.ShadeSlot;
const Slot = interface.Slot;

argb_depth: u8 = 0,
argb_visual: u32 = 0,
atoms: Atoms = .{},
colormap: u32 = 0,
cursor_font: u32 = 0,
cursor_ids: [cursor_count]u32 = @splat(0),
cursor_pixels: [cursor_module.image_pixels_max]u32 = undefined,
cursor_request: [cursor_request_bytes]u8 = undefined,
fatal: bool = false,
keyboard_owner: Owner = .none,
keyboard_window: u32 = 0,
monitor_count: u32 = 0,
monitor_rects: [monitor_module.count_max]Rect = @splat(.{}),
monitors_stale: bool = false,
placement_monitor: Rect = .{},
randr_event: u8 = 0,
randr_monitors: bool = false,
randr_opcode: u8 = 0,
render_format: u32 = 0,
render_opcode: u8 = 0,
request_bytes_limit: u32 = 0,
resource_base: u32 = 0,
resource_mask: u32 = 0,
resource_next: u32 = 1,
root: u32 = 0,
root_depth: u8 = 0,
root_visual: u32 = 0,
screen_height: u16 = 0,
screen_width: u16 = 0,
shades: [shade_module.count_max]Shade = @splat(.{}),
shape_opcode: u8 = 0,
socket: sys.Fd = -1,
state: *State,
surfaces: [surface_module.count_max]Surface = @splat(.{}),
work_area: Rect = .{},

pub const Error = Display.Error;

pub const atom_name_bytes_max: u32 = monitor_module.name_bytes_max * 2;
pub const chunk_bytes_max: u32 = 64 * 1024;
pub const cursor_count: u32 = @typeInfo(Cursor).@"enum".field_names.len;
pub const cursor_request_bytes: u32 = put_image_header + cursor_module.image_pixels_max * 4;
pub const extension_name_bytes_max: u32 = 32;
pub const keyboard_property_words_max: u32 = 8;
pub const keyboard_window_pixels: u16 = 1;
pub const message_attempts_max: u32 = 4096;
pub const monitor_refresh_rounds_max: u32 = 4;
pub const put_image_header: u32 = 24;
pub const request_bytes_max: u32 = 512;
pub const screen_name = "screen";
pub const send_words_max: u32 = 8;
pub const settle_errors_max: u32 = 64;
pub const setup_bytes_max: u32 = 32 * 1024;

comptime {
    assert(atom_name_bytes_max > monitor_module.name_bytes_max);
    assert(chunk_bytes_max > request_bytes_max);
    assert(cursor_request_bytes <= chunk_bytes_max);
    assert(cursor_count > 0);
    assert(extension_name_bytes_max % 4 == 0);
    assert(keyboard_property_words_max >= protocol.motif_hint_words);
    assert(keyboard_window_pixels > 0);
    assert(put_image_header == 24);
    assert(message_attempts_max > 0);
    assert(monitor_refresh_rounds_max > 0);
    assert(setup_bytes_max > 0);
    assert(send_words_max * 4 + 4 <= request_bytes_max);
    assert(settle_errors_max > 0);
}

pub const Translated = struct {
    input: Event.Input,
    window: u32,
};

pub const MonitorInfo = struct {
    atom: u32 = 0,
    primary: bool = false,
    rect: Rect = .{},
};

const Atoms = struct {
    motif_hints: u32 = 0,
    state: u32 = 0,
    state_skip_pager: u32 = 0,
    state_skip_taskbar: u32 = 0,
    window_type: u32 = 0,
    window_type_dialog: u32 = 0,
};

const Extension = struct {
    event: u8 = 0,
    opcode: u8 = 0,
};

const Owner = union(enum) {
    none: void,
    shade: u16,
    surface: u16,
};

const Shade = struct {
    frame: Rect = .{},
    interactive: bool = false,
    window: u32 = 0,
};

const Surface = struct {
    gc: u32 = 0,
    height: u32 = 0,
    mapped: bool = false,
    width: u32 = 0,
    window: u32 = 0,
};

pub fn open(client: *Client) Error!void {
    var environ: sys.Environ = .{};
    var path_storage: [sys.socket_path_bytes_max]u8 = undefined;

    environ.load();

    const display = environ.get("DISPLAY") orelse {
        return Error.Unavailable;
    };

    const number = display_number(display);
    const path = try resolve_socket(&path_storage, display);

    client.socket = sys.unix_socket() catch {
        return Error.Unavailable;
    };

    errdefer client.close();

    sys.connect_path(client.socket, path) catch {
        return Error.Unavailable;
    };

    client.fatal = false;
    client.resource_next = 1;

    try client.handshake(&environ, number);
    try client.select_visual();

    client.load_work_area();
    client.load_shape();
    client.load_randr();
    client.refresh_monitors();
    client.load_cursors(&environ);
}

pub fn close(client: *Client) void {
    var index: u16 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        assert(index < surface_module.count_max);

        client.destroy(index);
    }

    var shade_index: u16 = 0;

    while (shade_index < shade_module.count_max) : (shade_index += 1) {
        assert(shade_index < shade_module.count_max);

        client.shade_destroy(shade_index);
    }

    client.keyboard_close();

    if (client.socket >= 0) {
        sys.shutdown(client.socket);
        sys.close(client.socket);
    }

    client.argb_depth = 0;
    client.argb_visual = 0;
    client.atoms = .{};
    client.colormap = 0;
    client.cursor_font = 0;
    client.cursor_ids = @splat(0);
    client.fatal = false;
    client.monitor_count = 0;
    client.monitor_rects = @splat(.{});
    client.monitors_stale = false;
    client.placement_monitor = .{};
    client.randr_event = 0;
    client.randr_monitors = false;
    client.randr_opcode = 0;
    client.render_format = 0;
    client.render_opcode = 0;
    client.resource_next = 1;
    client.request_bytes_limit = 0;
    client.resource_base = 0;
    client.resource_mask = 0;
    client.root = 0;
    client.root_depth = 0;
    client.root_visual = 0;
    client.screen_height = 0;
    client.screen_width = 0;
    client.shape_opcode = 0;
    client.socket = -1;
    client.work_area = .{};

    assert(client.socket < 0);
    assert(client.keyboard_window == 0);
}

pub fn descriptor(client: *const Client) sys.Fd {
    return client.socket;
}

pub fn is_live(client: *const Client) bool {
    return client.socket >= 0 and !client.fatal;
}

pub fn take_restack(_: *Client) bool {
    return false;
}

pub fn create(client: *Client, index: u16, slot: *const Slot) Error!void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    if (entry.window != 0) {
        return;
    }

    entry.height = slot.height;
    entry.width = slot.width;
    entry.window = client.allocate();
    entry.gc = client.allocate();

    try client.create_window(entry);
    try client.create_gc(entry);
}

pub fn destroy(client: *Client, index: u16) void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    client.hide(index);

    if (entry.gc != 0) {
        client.free_gc(entry.gc) catch {
            client.fatal = true;
        };
    }

    if (entry.window != 0) {
        client.destroy_window(entry.window) catch {
            client.fatal = true;
        };
    }

    entry.* = .{};

    assert(entry.window == 0);
}

pub fn show(client: *Client, index: u16, slot: *const Slot) Error!void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    if (entry.window == 0) {
        return Error.Failed;
    }

    if (entry.mapped) {
        return;
    }

    client.load_work_area();

    const area = placement_area(client.placement_monitor, client.work_area);

    try client.configure(entry.window, placed_rect(area, slot));
    try client.map_window(entry.window);
    try client.configure_stack(entry.window);
    try client.keyboard_claim(.{ .surface = index });

    entry.mapped = true;

    assert(entry.mapped);
}

pub fn hide(client: *Client, index: u16) void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    if (!entry.mapped) {
        return;
    }

    entry.mapped = false;

    client.unmap_window(entry.window) catch {
        client.fatal = true;
    };

    client.keyboard_release(.{ .surface = index });

    assert(!entry.mapped);
}

pub fn is_mapped(client: *const Client, index: u16) bool {
    assert(index < surface_module.count_max);

    return client.surfaces[index].mapped;
}

pub fn present(client: *Client, index: u16, slot: *const Slot, pixels: []const u32) Error!void {
    assert(index < surface_module.count_max);
    assert(pixels.len <= slot.pixel_count());

    const entry = &client.surfaces[index];

    if (!entry.mapped) {
        return;
    }

    const stride = entry.width * 4;
    const bytes = std.mem.sliceAsBytes(pixels);

    if (stride == 0) {
        return Error.Failed;
    }

    if (bytes.len < stride * entry.height) {
        return Error.Failed;
    }

    const rows_per_chunk = client.rows_of(stride);

    var row: u32 = 0;

    while (row < entry.height) : (row += rows_per_chunk) {
        assert(rows_per_chunk > 0);

        const remaining = entry.height - row;
        const rows = @min(rows_per_chunk, remaining);

        try client.put_image(entry, row, rows, bytes[row * stride ..][0 .. rows * stride]);
    }
}

fn rows_of(client: *const Client, stride: u32) u32 {
    assert(stride > 0);

    const requested = client.request_bytes_limit;
    const limit = if (requested == 0) chunk_bytes_max else requested;
    const ceiling = @min(chunk_bytes_max, limit);

    if (ceiling <= request_bytes_max) {
        return 1;
    }

    const result = @max((ceiling - request_bytes_max) / stride, 1);

    assert(result > 0);

    return result;
}

pub fn pump(client: *Client) void {
    if (client.socket < 0) {
        return;
    }

    var header: [protocol.event_bytes]u8 = undefined;

    const count = sys.recv_discarding_fds(client.socket, &header) catch |err| {
        if (err == sys.Error.WouldBlock) {
            return;
        }

        client.fatal = true;

        return;
    };

    if (count < protocol.event_bytes) {
        client.fatal = true;

        return;
    }

    client.dispatch(&header);
    client.refresh_when_stale();
}

fn refresh_when_stale(client: *Client) void {
    var rounds: u32 = 0;

    while (rounds < monitor_refresh_rounds_max) : (rounds += 1) {
        if (!client.monitors_stale) {
            break;
        }

        client.monitors_stale = false;

        client.refresh_monitors();
    }
}

fn dispatch(client: *Client, header: *const [protocol.event_bytes]u8) void {
    const kind = header[0] & 0x7F;

    if (kind == protocol.reply_error) {
        client.fatal = true;

        return;
    }

    if (kind == protocol.reply_normal) {
        return;
    }

    if (client.is_randr_event(kind)) {
        client.monitors_stale = true;

        return;
    }

    const translated = translate(header) orelse return;

    switch (client.route(translated.window)) {
        .none => {},
        .shade => |index| client.state.publish_shade(index, translated.input),
        .surface => |index| client.state.publish(index, translated.input),
    }
}

fn route(client: *const Client, window: u32) Owner {
    if (client.keyboard_owner != .none) assert(client.keyboard_window != 0);

    if (window == 0) {
        return .none;
    }

    if (window == client.keyboard_window) {
        return client.keyboard_owner;
    }

    if (client.index_of(window)) |index| {
        return .{ .surface = index };
    }

    if (client.shade_index_of(window)) |index| {
        return .{ .shade = index };
    }

    return .none;
}

fn is_randr_event(client: *const Client, kind: u8) bool {
    if (client.randr_event == 0) {
        return false;
    }

    if (kind < client.randr_event) {
        return false;
    }

    return kind - client.randr_event < protocol.randr_events;
}

pub fn translate(header: *const [protocol.event_bytes]u8) ?Translated {
    const kind = header[0] & 0x7F;
    const detail = header[1];

    if (kind == protocol.event_focus_out) {
        const focused = std.mem.readInt(u32, header[4..8], .little);

        return .{ .input = .{ .focus_lost = {} }, .window = focused };
    }

    const window = std.mem.readInt(u32, header[12..16], .little);
    const x = std.mem.readInt(i16, header[24..26], .little);
    const y = std.mem.readInt(i16, header[26..28], .little);
    const point = event_module.Point{ .x = x, .y = y };
    const left = detail == protocol.button_left;

    const input: Event.Input = switch (kind) {
        protocol.event_key_press => .{ .key_down = protocol.to_key(detail) },
        protocol.event_button_press => if (left) .{ .pointer_down = point } else return null,
        protocol.event_button_release => if (left) .{ .pointer_up = point } else return null,
        protocol.event_motion_notify => .{ .pointer_move = point },
        protocol.event_leave_notify => .{ .pointer_leave = {} },
        else => return null,
    };

    return .{ .input = input, .window = window };
}

fn index_of(client: *const Client, window: u32) ?u16 {
    var index: u16 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        assert(index < surface_module.count_max);

        if (client.surfaces[index].window != 0) {
            if (client.surfaces[index].window == window) {
                return index;
            }
        }
    }

    return null;
}

fn shade_index_of(client: *const Client, window: u32) ?u16 {
    if (window == 0) {
        return null;
    }

    var index: u16 = 0;

    while (index < shade_module.count_max) : (index += 1) {
        assert(index < shade_module.count_max);

        if (client.shades[index].window == window) {
            return index;
        }
    }

    return null;
}

pub fn shade_create(client: *Client, index: u16, slot: *const ShadeSlot) Error!void {
    assert(index < shade_module.count_max);
    assert(slot.used);

    const entry = &client.shades[index];

    if (entry.window != 0) {
        client.shade_destroy(index);
    }

    if (client.colormap == 0) {
        return Error.Failed;
    }

    if (!slot.interactive) {
        if (client.shape_opcode == 0) return Error.Failed;
    }

    entry.window = client.allocate();
    entry.frame = client.shade_frame(slot.rect);

    errdefer client.shade_destroy(index);

    try client.create_shade_window(entry.window, entry.frame, slot);

    if (client.shape_opcode != 0) {
        try client.clip_shade(entry.window, entry.frame, slot.rect);
    }

    if (slot.interactive) {
        try client.point_window(entry.window, slot.cursor);
    } else {
        try client.clear_input_shape(entry.window);
    }

    try client.map_window(entry.window);
    try client.configure_stack(entry.window);

    if (slot.interactive) {
        entry.interactive = true;

        try client.keyboard_claim(.{ .shade = index });
    }

    assert(entry.window != 0);
}

pub fn shade_destroy(client: *Client, index: u16) void {
    assert(index < shade_module.count_max);

    const entry = &client.shades[index];

    if (entry.window != 0) {
        client.destroy_window(entry.window) catch {
            client.fatal = true;
        };
    }

    entry.* = .{};

    client.keyboard_release(.{ .shade = index });

    assert(entry.window == 0);
}

pub fn shade_fill(client: *Client, index: u16, color: u32) Error!void {
    assert(index < shade_module.count_max);

    const window = client.shades[index].window;

    if (window == 0) {
        return Error.Failed;
    }

    var change: [16]u8 = @splat(0);

    change[0] = protocol.opcode_change_window_attributes;

    std.mem.writeInt(u16, change[2..4], 4, .little);
    std.mem.writeInt(u32, change[4..8], window, .little);
    std.mem.writeInt(u32, change[8..12], protocol.attribute_back_pixel, .little);
    std.mem.writeInt(u32, change[12..16], shade_module.premultiply(color), .little);

    try client.send(&change);

    var clear: [16]u8 = @splat(0);

    clear[0] = protocol.opcode_clear_area;

    std.mem.writeInt(u16, clear[2..4], 4, .little);
    std.mem.writeInt(u32, clear[4..8], window, .little);

    try client.send(&clear);
}

pub fn shade_cursor(client: *Client, index: u16, cursor: Cursor) Error!void {
    assert(index < shade_module.count_max);
    assert(@backingInt(cursor) < cursor_count);

    const window = client.shades[index].window;

    if (window == 0) {
        return Error.Failed;
    }

    try client.point_window(window, cursor);
}

pub fn shade_place(client: *Client, index: u16, rect: Rect) Error!void {
    assert(index < shade_module.count_max);
    assert(rect.width > 0);
    assert(rect.height > 0);

    const entry = &client.shades[index];

    if (entry.window == 0) {
        return Error.Failed;
    }

    const frame = client.shade_frame(rect);

    if (!std.meta.eql(frame, entry.frame)) {
        try client.configure(entry.window, frame);

        entry.frame = frame;
    }

    if (client.shape_opcode != 0) {
        try client.clip_shade(entry.window, entry.frame, rect);
    }

    try client.touch_shade(entry.window, entry.frame, rect);

    assert(std.meta.eql(entry.frame, frame));
}

fn touch_shade(client: *Client, window: u32, frame: Rect, rect: Rect) Error!void {
    assert(window != 0);
    assert(frame.encloses(rect));

    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_clear_area;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(i16, request[8..10], @intCast(rect.x - frame.x), .little);
    std.mem.writeInt(i16, request[10..12], @intCast(rect.y - frame.y), .little);
    std.mem.writeInt(u16, request[12..14], 1, .little);
    std.mem.writeInt(u16, request[14..16], 1, .little);

    try client.send(&request);
}

fn shade_frame(client: *const Client, rect: Rect) Rect {
    assert(rect.width > 0);
    assert(rect.height > 0);

    if (client.shape_opcode == 0) {
        return rect;
    }

    const area = frame_area(client.monitor_rects[0..client.monitor_count], rect);

    if (area.width >= std.math.maxInt(u16)) {
        return area;
    }

    const result = Rect{ .height = area.height, .width = area.width + 1, .x = area.x, .y = area.y };

    assert(result.width <= std.math.maxInt(u16));
    assert(result.encloses(rect));

    return result;
}

pub fn frame_area(monitors: []const Rect, rect: Rect) Rect {
    assert(monitors.len <= monitor_module.count_max);
    assert(!rect.is_empty());

    for (monitors) |monitor| {
        if (monitor.encloses(rect)) return monitor;
    }

    return rect;
}

fn clip_shade(client: *Client, window: u32, frame: Rect, rect: Rect) Error!void {
    assert(window != 0);
    assert(client.shape_opcode != 0);
    assert(rect.width > 0);
    assert(rect.height > 0);
    assert(frame.encloses(rect));

    var request: [24]u8 = @splat(0);

    request[0] = client.shape_opcode;
    request[1] = protocol.shape_rectangles;
    request[4] = protocol.shape_operation_set;
    request[5] = protocol.shape_kind_bounding;
    request[6] = protocol.shape_ordering_unsorted;

    std.mem.writeInt(u16, request[2..4], 6, .little);
    std.mem.writeInt(u32, request[8..12], window, .little);
    std.mem.writeInt(i16, request[16..18], @intCast(rect.x - frame.x), .little);
    std.mem.writeInt(i16, request[18..20], @intCast(rect.y - frame.y), .little);
    std.mem.writeInt(u16, request[20..22], @intCast(rect.width), .little);
    std.mem.writeInt(u16, request[22..24], @intCast(rect.height), .little);

    try client.send(&request);
}

fn create_shade_window(
    client: *Client,
    window: u32,
    frame: Rect,
    slot: *const ShadeSlot,
) Error!void {
    assert(window != 0);
    assert(client.colormap != 0);
    assert(slot.rect.width > 0);
    assert(slot.rect.height > 0);
    assert(frame.encloses(slot.rect));

    const mask = protocol.attribute_back_pixel | protocol.attribute_border_pixel |
        protocol.attribute_override_redirect | protocol.attribute_event_mask |
        protocol.attribute_colormap;

    const events: u32 = if (slot.interactive) shade_event_mask() else 0;

    var request: [52]u8 = @splat(0);

    request[0] = protocol.opcode_create_window;
    request[1] = client.argb_depth;

    std.mem.writeInt(u16, request[2..4], 13, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], client.root, .little);
    std.mem.writeInt(i16, request[12..14], @intCast(frame.x), .little);
    std.mem.writeInt(i16, request[14..16], @intCast(frame.y), .little);
    std.mem.writeInt(u16, request[16..18], @intCast(frame.width), .little);
    std.mem.writeInt(u16, request[18..20], @intCast(frame.height), .little);
    std.mem.writeInt(u16, request[22..24], protocol.class_input_output, .little);
    std.mem.writeInt(u32, request[24..28], client.argb_visual, .little);
    std.mem.writeInt(u32, request[28..32], mask, .little);
    std.mem.writeInt(u32, request[32..36], shade_module.premultiply(slot.color), .little);
    std.mem.writeInt(u32, request[40..44], 1, .little);
    std.mem.writeInt(u32, request[44..48], events, .little);
    std.mem.writeInt(u32, request[48..52], client.colormap, .little);

    try client.send(&request);
}

fn shade_event_mask() u32 {
    const result = protocol.mask_button_press | protocol.mask_button_release |
        protocol.mask_pointer_motion;

    assert(result & protocol.mask_exposure == 0);

    return result;
}

fn clear_input_shape(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(client.shape_opcode != 0);

    var request: [16]u8 = @splat(0);

    request[0] = client.shape_opcode;
    request[1] = protocol.shape_rectangles;
    request[4] = protocol.shape_operation_set;
    request[5] = protocol.shape_kind_input;
    request[6] = protocol.shape_ordering_unsorted;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[8..12], window, .little);

    try client.send(&request);
}

fn keyboard_claim(client: *Client, owner: Owner) Error!void {
    assert(owner != .none);

    if (client.keyboard_window == 0) {
        try client.keyboard_open();
    }

    client.keyboard_owner = owner;

    assert(client.keyboard_window != 0);
}

fn keyboard_close(client: *Client) void {
    if (client.keyboard_window != 0) {
        client.destroy_window(client.keyboard_window) catch {
            client.fatal = true;
        };
    }

    client.keyboard_owner = .none;
    client.keyboard_window = 0;
}

fn keyboard_open(client: *Client) Error!void {
    assert(client.keyboard_window == 0);
    assert(client.keyboard_owner == .none);

    try client.load_atoms();

    const managed = try client.is_managed();

    client.keyboard_window = client.allocate();
    errdefer client.keyboard_close();

    try client.create_keyboard_window(client.keyboard_window);
    try client.describe_keyboard_window(client.keyboard_window);

    if (client.shape_opcode != 0) {
        try client.clear_input_shape(client.keyboard_window);
    }

    try client.map_window(client.keyboard_window);

    if (!managed) {
        try client.set_focus(client.keyboard_window);
    }

    assert(client.keyboard_window != 0);
}

fn keyboard_release(client: *Client, owner: Owner) void {
    assert(owner != .none);

    if (!std.meta.eql(client.keyboard_owner, owner)) {
        return;
    }

    const next = client.holder_next();

    if (next == .none) {
        client.keyboard_close();

        return;
    }

    client.keyboard_owner = next;

    assert(client.keyboard_window != 0);
}

fn holder_next(client: *const Client) Owner {
    var index: u16 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        if (client.surfaces[index].mapped) {
            assert(client.surfaces[index].window != 0);

            return .{ .surface = index };
        }
    }

    var shade_index: u16 = 0;

    while (shade_index < shade_module.count_max) : (shade_index += 1) {
        if (client.shades[shade_index].interactive) {
            assert(client.shades[shade_index].window != 0);

            return .{ .shade = shade_index };
        }
    }

    return .none;
}

fn is_managed(client: *Client) Error!bool {
    assert(client.root != 0);

    var request: [8]u8 = @splat(0);

    request[0] = protocol.opcode_get_window_attributes;

    std.mem.writeInt(u16, request[2..4], 2, .little);
    std.mem.writeInt(u32, request[4..8], client.root, .little);

    try client.send(&request);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    const extra = try client.wait_reply(&reply, &payload);

    if (extra < 4) {
        return Error.Failed;
    }

    const masks = std.mem.readInt(u32, payload[0..4], .little);

    return masks & protocol.mask_substructure_redirect != 0;
}

fn load_atoms(client: *Client) Error!void {
    if (client.atoms.window_type != 0) {
        return;
    }

    const loaded = Atoms{
        .motif_hints = try client.intern(protocol.motif_hints_atom),
        .state = try client.intern(protocol.state_atom),
        .state_skip_pager = try client.intern(protocol.state_skip_pager_atom),
        .state_skip_taskbar = try client.intern(protocol.state_skip_taskbar_atom),
        .window_type = try client.intern(protocol.window_type_atom),
        .window_type_dialog = try client.intern(protocol.window_type_dialog_atom),
    };

    assert(loaded.window_type != 0);
    assert(loaded.window_type_dialog != 0);

    client.atoms = loaded;
}

fn create_keyboard_window(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(client.root != 0);

    const uses_colormap = client.colormap != 0;

    var mask: u32 = protocol.attribute_back_pixel | protocol.attribute_border_pixel |
        protocol.attribute_event_mask;

    if (uses_colormap) {
        mask |= protocol.attribute_colormap;
    }

    const values: u32 = if (uses_colormap) 4 else 3;
    const length: u16 = @intCast(8 + values);

    var request: [48]u8 = @splat(0);

    request[0] = protocol.opcode_create_window;
    request[1] = if (uses_colormap) client.argb_depth else 0;

    std.mem.writeInt(u16, request[2..4], length, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], client.root, .little);
    std.mem.writeInt(u16, request[16..18], keyboard_window_pixels, .little);
    std.mem.writeInt(u16, request[18..20], keyboard_window_pixels, .little);
    std.mem.writeInt(u16, request[22..24], protocol.class_input_output, .little);
    std.mem.writeInt(u32, request[24..28], if (uses_colormap) client.argb_visual else 0, .little);
    std.mem.writeInt(u32, request[28..32], mask, .little);
    std.mem.writeInt(u32, request[32..36], 0, .little);
    std.mem.writeInt(u32, request[36..40], 0, .little);
    std.mem.writeInt(u32, request[40..44], keyboard_event_mask(), .little);

    if (uses_colormap) {
        std.mem.writeInt(u32, request[44..48], client.colormap, .little);
    }

    try client.send(request[0 .. @as(u32, length) * 4]);
}

fn keyboard_event_mask() u32 {
    const result = protocol.mask_key_press | protocol.mask_focus_change;

    assert(result & shade_event_mask() == 0);

    return result;
}

fn describe_keyboard_window(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(client.atoms.window_type != 0);

    const hints = [protocol.motif_hint_words]u32{ protocol.motif_hint_decorations, 0, 0, 0, 0 };
    const states = [_]u32{ client.atoms.state_skip_pager, client.atoms.state_skip_taskbar };
    const types = [_]u32{client.atoms.window_type_dialog};

    try client.change_property(window, client.atoms.motif_hints, client.atoms.motif_hints, &hints);
    try client.change_property(window, client.atoms.state, protocol.atom_atom, &states);
    try client.change_property(window, client.atoms.window_type, protocol.atom_atom, &types);
}

fn change_property(
    client: *Client,
    window: u32,
    property: u32,
    kind: u32,
    words: []const u32,
) Error!void {
    assert(window != 0);
    assert(property != 0);
    assert(kind != 0);
    assert(words.len <= keyboard_property_words_max);

    const length: u16 = @intCast(6 + words.len);

    var request: [24 + keyboard_property_words_max * 4]u8 = @splat(0);

    request[0] = protocol.opcode_change_property;
    request[1] = protocol.property_mode_replace;
    request[16] = protocol.property_format_words;

    std.mem.writeInt(u16, request[2..4], length, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], property, .little);
    std.mem.writeInt(u32, request[12..16], kind, .little);
    std.mem.writeInt(u32, request[20..24], @intCast(words.len), .little);

    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, request[24 + index * 4 ..][0..4], word, .little);
    }

    try client.send(request[0 .. @as(u32, length) * 4]);
}

fn handshake(client: *Client, environ: *const sys.Environ, number: []const u8) Error!void {
    assert(number.len > 0);
    assert(std.mem.findScalar(u8, number, ':') == null);

    const cookie = auth.load(environ, number);
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

    sys.write_all(client.socket, request[0..offset]) catch {
        return Error.Unavailable;
    };

    try client.read_setup();
}

fn read_setup(client: *Client) Error!void {
    var header: [8]u8 = undefined;
    var setup: [setup_bytes_max]u8 = undefined;

    sys.read_all(client.socket, &header) catch {
        return Error.Unavailable;
    };

    if (header[0] != protocol.setup_success) {
        return Error.Unavailable;
    }

    const words = std.mem.readInt(u16, header[6..8], .little);
    const length = @as(u32, words) * 4;

    if (length == 0) {
        return Error.Unavailable;
    }

    if (length > setup_bytes_max) {
        return Error.Unavailable;
    }

    sys.read_all(client.socket, setup[0..length]) catch {
        return Error.Unavailable;
    };

    try client.parse_setup(setup[0..length]);
}

fn parse_setup(client: *Client, bytes: []const u8) Error!void {
    assert(bytes.len <= setup_bytes_max);
    assert(bytes.len % 4 == 0);

    if (bytes.len < 32) {
        return Error.Unavailable;
    }

    client.resource_base = std.mem.readInt(u32, bytes[4..8], .little);
    client.resource_mask = std.mem.readInt(u32, bytes[8..12], .little);

    const vendor_len = std.mem.readInt(u16, bytes[16..18], .little);
    const request_length_max = std.mem.readInt(u16, bytes[18..20], .little);
    const screen_count = bytes[20];
    const format_count = bytes[21];
    const image_order = bytes[22];

    client.request_bytes_limit = @as(u32, request_length_max) * 4;

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

    client.root = std.mem.readInt(u32, bytes[offset..][0..4], .little);
    client.screen_width = std.mem.readInt(u16, bytes[offset + 20 ..][0..2], .little);
    client.screen_height = std.mem.readInt(u16, bytes[offset + 22 ..][0..2], .little);
    client.root_visual = std.mem.readInt(u32, bytes[offset + 32 ..][0..4], .little);
    client.root_depth = bytes[offset + 38];

    const depth_count = bytes[offset + 39];

    offset += 40;

    client.find_argb_visual(bytes, offset, depth_count);

    client.work_area = .{ .height = client.screen_height, .width = client.screen_width };

    if (client.root == 0) {
        return Error.Unavailable;
    }

    if (client.request_bytes_limit == 0) {
        return Error.Unavailable;
    }
}

fn find_argb_visual(client: *Client, bytes: []const u8, start: u32, depth_count: u8) void {
    assert(bytes.len <= setup_bytes_max);
    assert(start <= bytes.len);

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

            if (client.argb_visual == 0) {
                if (is_argb(depth, class)) {
                    client.argb_visual = identifier;
                    client.argb_depth = depth;
                }
            }

            offset += 24;
        }
    }
}

fn is_argb(depth: u8, class: u8) bool {
    if (depth != 32) {
        return false;
    }

    return class == protocol.class_true_color;
}

fn select_visual(client: *Client) Error!void {
    if (client.argb_visual == 0) {
        client.argb_visual = client.root_visual;
        client.argb_depth = client.root_depth;

        return;
    }

    client.colormap = client.allocate();

    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_create_colormap;
    request[1] = protocol.colormap_alloc_none;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], client.colormap, .little);
    std.mem.writeInt(u32, request[8..12], client.root, .little);
    std.mem.writeInt(u32, request[12..16], client.argb_visual, .little);

    try client.send(&request);
}

fn create_window(client: *Client, entry: *Surface) Error!void {
    const uses_colormap = client.colormap != 0;

    var mask: u32 = protocol.attribute_back_pixel | protocol.attribute_border_pixel |
        protocol.attribute_override_redirect | protocol.attribute_event_mask;

    if (uses_colormap) {
        mask |= protocol.attribute_colormap;
    }

    const values: u32 = if (uses_colormap) 5 else 4;
    const length: u16 = @intCast(8 + values);

    var request: [request_bytes_max]u8 = @splat(0);

    request[0] = protocol.opcode_create_window;
    request[1] = client.argb_depth;

    std.mem.writeInt(u16, request[2..4], length, .little);
    std.mem.writeInt(u32, request[4..8], entry.window, .little);
    std.mem.writeInt(u32, request[8..12], client.root, .little);
    std.mem.writeInt(u16, request[12..14], 0, .little);
    std.mem.writeInt(u16, request[14..16], 0, .little);
    std.mem.writeInt(u16, request[16..18], @intCast(entry.width), .little);
    std.mem.writeInt(u16, request[18..20], @intCast(entry.height), .little);
    std.mem.writeInt(u16, request[20..22], 0, .little);
    std.mem.writeInt(u16, request[22..24], protocol.class_input_output, .little);
    std.mem.writeInt(u32, request[24..28], client.argb_visual, .little);
    std.mem.writeInt(u32, request[28..32], mask, .little);
    std.mem.writeInt(u32, request[32..36], 0, .little);
    std.mem.writeInt(u32, request[36..40], 0, .little);
    std.mem.writeInt(u32, request[40..44], 1, .little);
    std.mem.writeInt(u32, request[44..48], event_mask(), .little);

    if (uses_colormap) {
        std.mem.writeInt(u32, request[48..52], client.colormap, .little);
    }

    try client.send(request[0 .. @as(u32, length) * 4]);
}

fn event_mask() u32 {
    const result = protocol.mask_button_press | protocol.mask_button_release |
        protocol.mask_leave_window | protocol.mask_pointer_motion | protocol.mask_exposure;

    assert(result != 0);

    return result;
}

fn create_gc(client: *Client, entry: *Surface) Error!void {
    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_create_gc;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], entry.gc, .little);
    std.mem.writeInt(u32, request[8..12], entry.window, .little);
    std.mem.writeInt(u32, request[12..16], 0, .little);

    try client.send(&request);
}

fn free_gc(client: *Client, gc: u32) Error!void {
    assert(gc != 0);
    assert(gc != client.root);

    var request: [8]u8 = @splat(0);

    request[0] = protocol.opcode_free_gc;

    std.mem.writeInt(u16, request[2..4], 2, .little);
    std.mem.writeInt(u32, request[4..8], gc, .little);

    try client.send(&request);
}

fn destroy_window(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(window != client.root);

    try client.simple(protocol.opcode_destroy_window, window);
}

fn map_window(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(window != client.root);

    try client.simple(protocol.opcode_map_window, window);
}

fn unmap_window(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(window != client.root);

    try client.simple(protocol.opcode_unmap_window, window);
}

fn simple(client: *Client, opcode: u8, window: u32) Error!void {
    assert(window != 0);
    assert(window != client.root);

    var request: [8]u8 = @splat(0);

    request[0] = opcode;

    std.mem.writeInt(u16, request[2..4], 2, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);

    try client.send(&request);
}

fn placement_area(monitor: Rect, work: Rect) Rect {
    assert(monitor.width >= 0);
    assert(monitor.height >= 0);
    assert(!work.is_empty());

    const overlap = monitor.intersect(work);
    const result = if (overlap.is_empty()) work else overlap;

    assert(!result.is_empty());

    return result;
}

fn placement_monitor_of(list: *const Monitor.List) Rect {
    assert(list.count > 0);
    assert(list.count <= monitor_module.count_max);

    var result = list.items[0].rect;

    for (list.items[1..list.count]) |*monitor| {
        if (monitor.primary) {
            result = monitor.rect;

            break;
        }
    }

    assert(result.width >= 0);
    assert(result.height >= 0);

    return result;
}

fn placed_rect(work: Rect, slot: *const Slot) Rect {
    assert(!work.is_empty());

    const placement = geometry.placement_of(slot);
    const origin = geometry.anchor_point(work, placement);

    const result = Rect{
        .height = placement.height,
        .width = placement.width,
        .x = origin.x,
        .y = origin.y,
    };

    assert(result.x >= work.x);
    assert(result.y >= work.y);

    return result;
}

fn configure(client: *Client, window: u32, placed: Rect) Error!void {
    assert(window != 0);
    assert(window != client.root);
    assert(placed.width > 0);
    assert(placed.width <= std.math.maxInt(u16));
    assert(placed.height > 0);
    assert(placed.height <= std.math.maxInt(u16));

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

    try client.send(&request);
}

fn configure_stack(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(window != client.root);

    var request: [16]u8 = @splat(0);

    request[0] = protocol.opcode_configure_window;

    std.mem.writeInt(u16, request[2..4], 4, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u16, request[8..10], protocol.configure_stack_mode, .little);
    std.mem.writeInt(u32, request[12..16], protocol.stack_above, .little);

    try client.send(&request);
}

fn set_focus(client: *Client, window: u32) Error!void {
    assert(window != 0);
    assert(window != client.root);

    var request: [12]u8 = @splat(0);

    request[0] = protocol.opcode_set_input_focus;
    request[1] = protocol.revert_to_parent;

    std.mem.writeInt(u16, request[2..4], 3, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], 0, .little);

    try client.send(&request);
}

fn put_image(
    client: *Client,
    entry: *const Surface,
    row: u32,
    rows: u32,
    bytes: []const u8,
) Error!void {
    assert(row < entry.height);
    assert(rows > 0);
    assert(row + rows <= entry.height);
    assert(bytes.len == rows * entry.width * 4);

    const padded = protocol.pad(@intCast(bytes.len));
    const total = put_image_header + padded;

    if (total > chunk_bytes_max) {
        return Error.Failed;
    }

    var chunk: [chunk_bytes_max]u8 = undefined;

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
    chunk[21] = client.argb_depth;

    @memcpy(chunk[put_image_header..][0..bytes.len], bytes);
    @memset(chunk[put_image_header + bytes.len ..][0 .. padded - bytes.len], 0);

    try client.send(chunk[0..total]);
}

fn load_work_area(client: *Client) void {
    const atom = client.intern(protocol.workarea_atom) catch {
        return;
    };

    if (atom == 0) {
        return;
    }

    var value: [16]u8 = @splat(0);

    const filled = client.get_property(client.root, atom, &value) catch {
        return;
    };

    if (filled < 16) {
        return;
    }

    client.work_area = .{
        .x = @bitCast(std.mem.readInt(u32, value[0..4], .little)),
        .y = @bitCast(std.mem.readInt(u32, value[4..8], .little)),
        .width = @bitCast(std.mem.readInt(u32, value[8..12], .little)),
        .height = @bitCast(std.mem.readInt(u32, value[12..16], .little)),
    };

    if (client.work_area.width > 0) {
        if (client.work_area.height > 0) {
            return;
        }
    }

    client.work_area = .{ .height = client.screen_height, .width = client.screen_width };
}

fn load_shape(client: *Client) void {
    const extension = client.query_extension(protocol.extension_shape) catch return;

    if (extension.opcode == 0) {
        return;
    }

    var request: [4]u8 = @splat(0);

    request[0] = extension.opcode;
    request[1] = protocol.shape_query_version;

    std.mem.writeInt(u16, request[2..4], 1, .little);

    client.send(&request) catch return;

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    _ = client.wait_reply(&reply, &payload) catch return;

    const major = std.mem.readInt(u16, reply[8..10], .little);
    const minor = std.mem.readInt(u16, reply[10..12], .little);

    if (supports(major, minor, 1, 1)) {
        client.shape_opcode = extension.opcode;
    }
}

fn load_randr(client: *Client) void {
    const extension = client.query_extension(protocol.extension_randr) catch return;

    if (extension.opcode == 0) {
        return;
    }

    var request: [12]u8 = @splat(0);

    request[0] = extension.opcode;
    request[1] = protocol.randr_query_version;

    std.mem.writeInt(u16, request[2..4], 3, .little);
    std.mem.writeInt(u32, request[4..8], 1, .little);
    std.mem.writeInt(u32, request[8..12], 5, .little);

    client.send(&request) catch return;

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    _ = client.wait_reply(&reply, &payload) catch return;

    const major = std.mem.readInt(u32, reply[8..12], .little);
    const minor = std.mem.readInt(u32, reply[12..16], .little);

    client.randr_opcode = extension.opcode;
    client.randr_event = extension.event;
    client.randr_monitors = supports(major, minor, 1, 5);

    client.select_randr() catch return;
}

fn select_randr(client: *Client) Error!void {
    assert(client.randr_opcode != 0);
    assert(client.root != 0);

    const mask = protocol.randr_notify_screen_change | protocol.randr_notify_crtc_change |
        protocol.randr_notify_output_change;

    var request: [12]u8 = @splat(0);

    request[0] = client.randr_opcode;
    request[1] = protocol.randr_select_input;

    std.mem.writeInt(u16, request[2..4], 3, .little);
    std.mem.writeInt(u32, request[4..8], client.root, .little);
    std.mem.writeInt(u16, request[8..10], mask, .little);

    try client.send(&request);
}

pub fn supports(major: u32, minor: u32, wanted_major: u32, wanted_minor: u32) bool {
    if (major != wanted_major) {
        return major > wanted_major;
    }

    return minor >= wanted_minor;
}

fn load_cursors(client: *Client, environ: *const sys.Environ) void {
    assert(client.socket >= 0);
    assert(client.root != 0);

    var resources: [cursor_module.index_bytes_max]u8 = @splat(0);

    const filled = client.read_resources(&resources);
    const settings = cursor_module.settings_of(environ, resources[0..filled]);

    client.load_render();

    for (std.enums.values(Cursor)) |cursor| {
        client.cursor_ids[@backingInt(cursor)] = client.make_cursor(environ, &settings, cursor);
    }
}

fn read_resources(client: *Client, storage: *[cursor_module.index_bytes_max]u8) u32 {
    assert(client.root != 0);

    const atom = client.intern(protocol.resource_manager_atom) catch return 0;
    if (atom == 0) return 0;

    const result = client.get_property(client.root, atom, storage) catch return 0;

    assert(result <= storage.len);

    return result;
}

fn load_render(client: *Client) void {
    assert(client.render_opcode == 0);
    assert(client.render_format == 0);

    const extension = client.query_extension(protocol.extension_render) catch return;

    if (extension.opcode == 0) {
        return;
    }

    const format = client.query_render(extension.opcode) catch return;

    if (format == 0) {
        return;
    }

    client.render_format = format;
    client.render_opcode = extension.opcode;
}

fn query_render(client: *Client, opcode: u8) Error!u32 {
    assert(opcode != 0);

    var version: [12]u8 = @splat(0);

    version[0] = opcode;
    version[1] = protocol.render_query_version;

    std.mem.writeInt(u16, version[2..4], 3, .little);
    std.mem.writeInt(u32, version[4..8], 0, .little);
    std.mem.writeInt(u32, version[8..12], 11, .little);

    try client.send(&version);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    _ = try client.wait_reply(&reply, &payload);

    const major = std.mem.readInt(u32, reply[8..12], .little);
    const minor = std.mem.readInt(u32, reply[12..16], .little);

    if (!supports(major, minor, 0, 5)) return 0;

    var formats: [4]u8 = @splat(0);

    formats[0] = opcode;
    formats[1] = protocol.render_query_pict_formats;

    std.mem.writeInt(u16, formats[2..4], 1, .little);

    try client.send(&formats);

    const extra = try client.wait_reply(&reply, &payload);
    const count = std.mem.readInt(u32, reply[8..12], .little);
    const listed = @min(count, extra / protocol.render_format_bytes);
    const result = argb_format_of(payload[0 .. listed * protocol.render_format_bytes]);

    if (result != 0) assert(listed > 0);

    return result;
}

pub fn argb_format_of(formats: []const u8) u32 {
    assert(formats.len % protocol.render_format_bytes == 0);
    assert(formats.len <= chunk_bytes_max);

    const size = protocol.render_format_bytes;
    const total: u32 = @intCast(formats.len / size);

    var index: u32 = 0;

    while (index < total) : (index += 1) {
        assert(index < total);

        const entry = formats[index * size ..][0..size];

        if (is_argb_format(entry)) {
            return std.mem.readInt(u32, entry[0..4], .little);
        }
    }

    return 0;
}

fn is_argb_format(entry: *const [protocol.render_format_bytes]u8) bool {
    const wanted = [8]u16{ 16, 0xFF, 8, 0xFF, 0, 0xFF, 24, 0xFF };

    if (entry[4] != protocol.render_type_direct) return false;
    if (entry[5] != 32) return false;

    for (wanted, 0..) |value, position| {
        const offset = 8 + position * 2;

        if (std.mem.readInt(u16, entry[offset..][0..2], .little) != value) return false;
    }

    return true;
}

fn make_cursor(
    client: *Client,
    environ: *const sys.Environ,
    settings: *const cursor_module.Settings,
    cursor: Cursor,
) u32 {
    assert(client.socket >= 0);
    assert(settings.size > 0);

    if (client.render_format != 0) {
        if (cursor_module.load(environ, settings, cursor, &client.cursor_pixels)) |image| {
            const pixels = client.cursor_pixels[0..image.pixel_count()];
            const themed = client.upload_cursor(image, pixels) catch 0;

            if (themed != 0) {
                if (client.settle()) return themed;
            }
        }
    }

    const glyph = client.glyph_cursor(cursor) catch return 0;

    if (!client.settle()) return 0;

    return glyph;
}

fn upload_cursor(client: *Client, image: cursor_module.Image, pixels: []const u32) Error!u32 {
    assert(client.render_format != 0);
    assert(pixels.len == image.pixel_count());

    const pixmap = client.allocate();
    const gc = client.allocate();
    const picture = client.allocate();
    const result = client.allocate();

    try client.send_words(protocol.opcode_create_pixmap, 32, &.{
        pixmap,
        client.root,
        @as(u32, image.height) << 16 | image.width,
    });

    try client.send_words(protocol.opcode_create_gc, 0, &.{ gc, pixmap, 0 });
    try client.put_cursor_image(pixmap, gc, image, pixels);

    try client.send_words(client.render_opcode, protocol.render_create_picture, &.{
        picture,
        pixmap,
        client.render_format,
        0,
    });

    try client.send_words(client.render_opcode, protocol.render_create_cursor, &.{
        result,
        picture,
        @as(u32, image.hot_y) << 16 | image.hot_x,
    });

    try client.send_words(client.render_opcode, protocol.render_free_picture, &.{picture});
    try client.free_gc(gc);
    try client.send_words(protocol.opcode_free_pixmap, 0, &.{pixmap});

    return result;
}

fn put_cursor_image(
    client: *Client,
    pixmap: u32,
    gc: u32,
    image: cursor_module.Image,
    pixels: []const u32,
) Error!void {
    assert(pixmap != 0);
    assert(gc != 0);
    assert(pixels.len == image.pixel_count());

    const bytes = std.mem.sliceAsBytes(pixels);
    const total = put_image_header + bytes.len;

    assert(total <= client.cursor_request.len);

    @memset(client.cursor_request[0..put_image_header], 0);

    client.cursor_request[0] = protocol.opcode_put_image;
    client.cursor_request[1] = protocol.format_z_pixmap;

    std.mem.writeInt(u16, client.cursor_request[2..4], @intCast(total / 4), .little);
    std.mem.writeInt(u32, client.cursor_request[4..8], pixmap, .little);
    std.mem.writeInt(u32, client.cursor_request[8..12], gc, .little);
    std.mem.writeInt(u16, client.cursor_request[12..14], image.width, .little);
    std.mem.writeInt(u16, client.cursor_request[14..16], image.height, .little);

    client.cursor_request[21] = 32;

    @memcpy(client.cursor_request[put_image_header..][0..bytes.len], bytes);

    try client.send(client.cursor_request[0..total]);
}

fn glyph_cursor(client: *Client, cursor: Cursor) Error!u32 {
    assert(client.socket >= 0);
    assert(@backingInt(cursor) < cursor_count);

    if (client.cursor_font == 0) {
        const font = client.allocate();

        try client.open_font(font, protocol.cursor_font_name);

        client.cursor_font = font;
    }

    const glyph = cursor_module.glyph_of(cursor);
    const result = client.allocate();

    try client.send_words(protocol.opcode_create_glyph_cursor, 0, &.{
        result,
        client.cursor_font,
        client.cursor_font,
        @as(u32, glyph + 1) << 16 | glyph,
        0,
        0xFFFF << 16,
        0xFFFF << 16 | 0xFFFF,
    });

    return result;
}

fn open_font(client: *Client, font: u32, name: []const u8) Error!void {
    assert(font != 0);
    assert(name.len > 0);
    assert(name.len <= extension_name_bytes_max);

    const padded = protocol.pad(@intCast(name.len));
    const total = 12 + padded;

    var request: [12 + extension_name_bytes_max]u8 = @splat(0);

    request[0] = protocol.opcode_open_font;

    std.mem.writeInt(u16, request[2..4], @intCast(total / 4), .little);
    std.mem.writeInt(u32, request[4..8], font, .little);
    std.mem.writeInt(u16, request[8..10], @intCast(name.len), .little);

    @memcpy(request[12..][0..name.len], name);

    try client.send(request[0..total]);
}

fn point_window(client: *Client, window: u32, cursor: Cursor) Error!void {
    assert(window != 0);
    assert(window != client.root);

    try client.send_words(protocol.opcode_change_window_attributes, 0, &.{
        window,
        protocol.attribute_cursor,
        client.cursor_ids[@backingInt(cursor)],
    });
}

fn settle(client: *Client) bool {
    client.send_words(protocol.opcode_get_input_focus, 0, &.{}) catch return false;

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;
    var clean = true;
    var attempts: u32 = 0;

    while (attempts < settle_errors_max) : (attempts += 1) {
        _ = client.wait_reply(&reply, &payload) catch {
            if (client.fatal) return false;

            clean = false;

            continue;
        };

        return clean;
    }

    return false;
}

fn send_words(client: *Client, opcode: u8, detail: u8, words: []const u32) Error!void {
    assert(opcode != 0);
    assert(words.len < send_words_max);

    var request: [4 + 4 * send_words_max]u8 = @splat(0);
    const total = 4 + 4 * words.len;

    request[0] = opcode;
    request[1] = detail;

    std.mem.writeInt(u16, request[2..4], @intCast(total / 4), .little);

    for (words, 0..) |word, position| {
        std.mem.writeInt(u32, request[4 + 4 * position ..][0..4], word, .little);
    }

    try client.send(request[0..total]);
}

fn query_extension(client: *Client, name: []const u8) Error!Extension {
    assert(name.len > 0);
    assert(name.len <= extension_name_bytes_max);

    const padded = protocol.pad(@intCast(name.len));
    const total = 8 + padded;

    var request: [8 + extension_name_bytes_max]u8 = @splat(0);

    request[0] = protocol.opcode_query_extension;

    std.mem.writeInt(u16, request[2..4], @intCast(total / 4), .little);
    std.mem.writeInt(u16, request[4..6], @intCast(name.len), .little);

    @memcpy(request[8..][0..name.len], name);

    try client.send(request[0..total]);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    _ = try client.wait_reply(&reply, &payload);

    if (reply[8] == 0) {
        return .{};
    }

    return .{ .event = reply[10], .opcode = reply[9] };
}

fn refresh_monitors(client: *Client) void {
    var list = Monitor.List.init();

    if (client.randr_monitors) {
        client.load_monitors(&list) catch {
            list.clear();
        };
    }

    if (list.count == 0) {
        const screen = Rect{ .height = client.screen_height, .width = client.screen_width };

        list.append(Monitor.init(screen_name, screen));
    }

    client.placement_monitor = placement_monitor_of(&list);
    client.monitor_count = list.count;

    for (list.slice(), 0..) |*monitor, index| {
        client.monitor_rects[index] = monitor.rect;
    }

    client.state.set_monitors(&list);

    assert(client.monitor_count <= monitor_module.count_max);
}

fn load_monitors(client: *Client, list: *Monitor.List) Error!void {
    assert(client.randr_opcode != 0);
    assert(list.count == 0);

    var request: [12]u8 = @splat(0);

    request[0] = client.randr_opcode;
    request[1] = protocol.randr_get_monitors;
    request[8] = 1;

    std.mem.writeInt(u16, request[2..4], 3, .little);
    std.mem.writeInt(u32, request[4..8], client.root, .little);

    try client.send(&request);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;
    var found: [monitor_module.count_max]MonitorInfo = undefined;

    const extra = try client.wait_reply(&reply, &payload);
    const count = std.mem.readInt(u32, reply[12..16], .little);
    const parsed = parse_monitors(payload[0..extra], count, &found);

    for (found[0..parsed]) |info| {
        var storage: [atom_name_bytes_max]u8 = undefined;

        const name = client.atom_name(info.atom, &storage) catch screen_name;
        var monitor = Monitor.init(name, info.rect);
        monitor.primary = info.primary;

        list.append(monitor);
    }

    assert(list.count == parsed);
}

pub fn parse_monitors(payload: []const u8, count: u32, found: []MonitorInfo) u32 {
    assert(found.len > 0);
    assert(payload.len <= chunk_bytes_max);

    const fits: u32 = @intCast(payload.len / protocol.monitor_info_bytes);
    const bounded = @min(count, fits);

    var offset: u32 = 0;
    var parsed: u32 = 0;
    var index: u32 = 0;

    while (index < bounded) : (index += 1) {
        if (parsed == found.len) break;
        if (offset + protocol.monitor_info_bytes > payload.len) break;

        const info = payload[offset..][0..protocol.monitor_info_bytes];
        const outputs = std.mem.readInt(u16, info[6..8], .little);
        const size = protocol.monitor_info_bytes + @as(u32, outputs) * 4;
        if (offset + size > payload.len) break;

        const rect = Rect{
            .height = std.mem.readInt(u16, info[14..16], .little),
            .width = std.mem.readInt(u16, info[12..14], .little),
            .x = std.mem.readInt(i16, info[8..10], .little),
            .y = std.mem.readInt(i16, info[10..12], .little),
        };

        offset += size;

        if (!rect.is_empty()) {
            const atom = std.mem.readInt(u32, info[0..4], .little);

            found[parsed] = .{ .atom = atom, .primary = info[4] != 0, .rect = rect };
            parsed += 1;
        }
    }

    assert(parsed <= found.len);
    assert(parsed <= count);

    return parsed;
}

fn atom_name(client: *Client, atom: u32, storage: []u8) Error![]const u8 {
    assert(storage.len > 0);

    if (atom == 0) {
        return Error.Failed;
    }

    var request: [8]u8 = @splat(0);

    request[0] = protocol.opcode_get_atom_name;

    std.mem.writeInt(u16, request[2..4], 2, .little);
    std.mem.writeInt(u32, request[4..8], atom, .little);

    try client.send(&request);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    const extra = try client.wait_reply(&reply, &payload);
    const length = std.mem.readInt(u16, reply[8..10], .little);
    const kept = @min(length, extra, storage.len);

    @memcpy(storage[0..kept], payload[0..kept]);

    return storage[0..kept];
}

fn intern(client: *Client, name: []const u8) Error!u32 {
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

    try client.send(request[0..total]);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    const extra = try client.wait_reply(&reply, &payload);

    _ = extra;

    return std.mem.readInt(u32, reply[8..12], .little);
}

fn get_property(client: *Client, window: u32, property: u32, value: []u8) Error!u32 {
    assert(window != 0);
    assert(property != 0);
    assert(value.len > 0);
    assert(value.len % 4 == 0);
    assert(value.len <= chunk_bytes_max);

    var request: [24]u8 = @splat(0);

    request[0] = protocol.opcode_get_property;

    std.mem.writeInt(u16, request[2..4], 6, .little);
    std.mem.writeInt(u32, request[4..8], window, .little);
    std.mem.writeInt(u32, request[8..12], property, .little);
    std.mem.writeInt(u32, request[12..16], 0, .little);
    std.mem.writeInt(u32, request[16..20], 0, .little);
    std.mem.writeInt(u32, request[20..24], @intCast(value.len / 4), .little);

    try client.send(&request);

    var payload: [chunk_bytes_max]u8 = undefined;
    var reply: [protocol.event_bytes]u8 = undefined;

    const extra = try client.wait_reply(&reply, &payload);

    if (extra == 0) {
        return 0;
    }

    const wanted = @min(extra, value.len);

    @memcpy(value[0..wanted], payload[0..wanted]);

    const result: u32 = @intCast(wanted);
    assert(result <= value.len);

    return result;
}

fn wait_reply(
    client: *Client,
    reply: *[protocol.event_bytes]u8,
    payload: *[chunk_bytes_max]u8,
) Error!u32 {
    var attempts: u32 = 0;

    while (attempts < message_attempts_max) : (attempts += 1) {
        assert(attempts < message_attempts_max);

        sys.read_all(client.socket, reply) catch {
            client.fatal = true;

            return Error.Failed;
        };

        const kind = reply[0] & 0x7F;

        if (kind == protocol.reply_error) {
            return Error.Failed;
        }

        if (kind != protocol.reply_normal) {
            client.dispatch(reply);

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

        sys.read_all(client.socket, payload[0..extra]) catch {
            client.fatal = true;

            return Error.Failed;
        };

        assert(extra <= payload.len);

        return extra;
    }

    return Error.Failed;
}

fn send(client: *Client, bytes: []const u8) Error!void {
    assert(bytes.len >= 4);
    assert(@as(usize, std.mem.readInt(u16, bytes[2..4], .little)) * 4 == bytes.len);

    sys.write_all(client.socket, bytes) catch {
        client.fatal = true;

        return Error.Failed;
    };
}

fn allocate(client: *Client) u32 {
    const result = client.resource_base | (client.resource_next & client.resource_mask);

    client.resource_next += 1;

    assert(client.resource_next > 1);

    return result;
}

pub fn display_number(display: []const u8) []const u8 {
    const colon = std.mem.findScalarLast(u8, display, ':') orelse return "";
    const tail = display[colon + 1 ..];
    const dot = std.mem.findScalar(u8, tail, '.') orelse return tail;

    return tail[0..dot];
}

pub fn resolve_socket(storage: []u8, display: []const u8) Error![]const u8 {
    assert(storage.len > 0);

    const number = display_number(display);

    if (number.len == 0) {
        return Error.Unavailable;
    }

    const result = std.mem.print(storage, "/tmp/.X11-unix/X{s}", .{number}) catch {
        return Error.Unavailable;
    };

    return result;
}

const testing = std.testing;

test "a shade inside one monitor is framed by that monitor and any other rect frames itself" {
    const left = Rect{ .height = 1080, .width = 1920, .x = 0, .y = 0 };
    const right = Rect{ .height = 1080, .width = 1920, .x = 1920, .y = 0 };
    const monitors = [_]Rect{ left, right };
    const inside = Rect{ .height = 300, .width = 400, .x = 2000, .y = 100 };
    const across = Rect{ .height = 300, .width = 400, .x = 1800, .y = 100 };
    const corner = Rect{ .height = 1, .width = 1, .x = 1919, .y = 1079 };
    const spill = Rect{ .height = 1, .width = 2, .x = 1919, .y = 0 };

    try testing.expectEqual(right, frame_area(&monitors, inside));
    try testing.expectEqual(across, frame_area(&monitors, across));
    try testing.expectEqual(right, frame_area(&monitors, right));
    try testing.expectEqual(inside, frame_area(&.{}, inside));
    try testing.expect(left.encloses(corner));
    try testing.expect(!left.encloses(spill));

    var prng = std.Random.DefaultPrng.init(0x6672616d65);
    const random = prng.random();
    var round: u32 = 0;

    while (round < 1024) : (round += 1) {
        const rect = Rect{
            .height = random.intRangeAtMost(i32, 1, 1200),
            .width = random.intRangeAtMost(i32, 1, 2400),
            .x = random.intRangeAtMost(i32, -500, 4000),
            .y = random.intRangeAtMost(i32, -200, 1200),
        };

        const frame = frame_area(&monitors, rect);

        try testing.expect(frame.encloses(rect));

        if (!std.meta.eql(frame, rect)) {
            try testing.expect(std.meta.eql(frame, left) or std.meta.eql(frame, right));
        }
    }
}

test "an anchored surface keeps the size it was asked for" {
    const work = Rect{ .height = 1040, .width = 1920, .x = 0, .y = 0 };
    const slot = Slot{ .height = 220, .margin = 12, .used = true, .width = 380 };
    const placed = placed_rect(work, &slot);

    try testing.expectEqual(@as(i32, 380), placed.width);
    try testing.expectEqual(@as(i32, 220), placed.height);
    try testing.expectEqual(@as(i32, 1528), placed.x);
    try testing.expectEqual(@as(i32, 808), placed.y);
}

test "a surface anchors to the primary monitor's share of the work area" {
    const work = Rect{ .height = 997, .width = 5760, .x = 0, .y = 32 };
    const slot = Slot{ .height = 220, .margin = 12, .used = true, .width = 380 };
    var middle = Monitor.init("DP-4", .{ .height = 1080, .width = 1920, .x = 1920, .y = 0 });
    middle.primary = true;
    var list = Monitor.List.init();

    list.append(Monitor.init("HDMI-5", .{ .height = 1080, .width = 1920, .x = 0, .y = 0 }));
    list.append(middle);
    list.append(Monitor.init("DP-5", .{ .height = 1080, .width = 1920, .x = 3840, .y = 0 }));

    const area = placement_area(placement_monitor_of(&list), work);
    const placed = placed_rect(area, &slot);

    try testing.expectEqual(Rect{ .height = 997, .width = 1920, .x = 1920, .y = 32 }, area);
    try testing.expectEqual(@as(i32, 3448), placed.x);
    try testing.expectEqual(@as(i32, 797), placed.y);
}

test "a missing primary falls back to the first monitor and no overlap to the work area" {
    const work = Rect{ .height = 1040, .width = 1920, .x = 0, .y = 0 };
    const beside = Rect{ .height = 1080, .width = 1920, .x = 1920, .y = 0 };
    var list = Monitor.List.init();

    list.append(Monitor.init("DP-1", .{ .height = 1080, .width = 1920, .x = 0, .y = 0 }));
    list.append(Monitor.init("DP-2", beside));

    try testing.expectEqual(list.items[0].rect, placement_monitor_of(&list));
    try testing.expectEqual(work, placement_area(beside, work));
    try testing.expectEqual(work, placement_area(.{}, work));
}

test "a display string yields the screen number the socket is named after" {
    try testing.expectEqualStrings("0", display_number(":0"));
    try testing.expectEqualStrings("0", display_number(":0.0"));
    try testing.expectEqualStrings("1", display_number("localhost:1.0"));
    try testing.expectEqualStrings("", display_number("nonsense"));
}

test "a socket path is built from the display number" {
    var storage: [sys.socket_path_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("/tmp/.X11-unix/X0", try resolve_socket(&storage, ":0"));
    try testing.expectEqualStrings("/tmp/.X11-unix/X1", try resolve_socket(&storage, ":1.0"));
    try testing.expectError(Error.Unavailable, resolve_socket(&storage, "nonsense"));
}

fn event_header(kind: u8, detail: u8) [protocol.event_bytes]u8 {
    var result: [protocol.event_bytes]u8 = @splat(0);

    result[0] = kind;
    result[1] = detail;

    std.mem.writeInt(u32, result[4..8], 0x0400_0004, .little);
    std.mem.writeInt(u32, result[8..12], 0x0000_0123, .little);
    std.mem.writeInt(u32, result[12..16], 0x0400_0010, .little);
    std.mem.writeInt(i16, result[20..22], 1900, .little);
    std.mem.writeInt(i16, result[22..24], 700, .little);
    std.mem.writeInt(i16, result[24..26], -3, .little);
    std.mem.writeInt(i16, result[26..28], 45, .little);

    return result;
}

test "an input event names the window it was delivered to, never the root" {
    const pressed = translate(&event_header(protocol.event_button_press, protocol.button_left)).?;
    const typed = translate(&event_header(protocol.event_key_press, protocol.key_escape)).?;
    const moved = translate(&event_header(protocol.event_motion_notify | 0x80, 0)).?;
    const left = translate(&event_header(protocol.event_leave_notify, 0)).?;

    try testing.expectEqual(@as(u32, 0x0400_0010), pressed.window);
    try testing.expect(pressed.input.pointer_down.eql(.{ .x = -3, .y = 45 }));
    try testing.expectEqual(@as(u32, 0x0400_0010), typed.window);
    try testing.expectEqual(event_module.Key.escape, typed.input.key_down);
    try testing.expect(moved.input.pointer_move.eql(.{ .x = -3, .y = 45 }));
    try testing.expect(left.input == .pointer_leave);
}

test "a focus change names the window from its own field" {
    const lost = translate(&event_header(protocol.event_focus_out, 0)).?;

    try testing.expectEqual(@as(u32, 0x0400_0004), lost.window);
    try testing.expect(lost.input == .focus_lost);
}

test "a right click and an expose carry no input" {
    try testing.expect(translate(&event_header(protocol.event_button_press, 3)) == null);
    try testing.expect(translate(&event_header(protocol.event_button_release, 2)) == null);
    try testing.expect(translate(&event_header(protocol.event_expose, 0)) == null);
}

test "keys on the keyboard window reach the overlay that holds the keyboard" {
    var client: Client = .{ .state = undefined };

    client.surfaces[1] = .{ .mapped = true, .window = 0x101 };
    client.shades[2] = .{ .interactive = true, .window = 0x202 };
    client.keyboard_owner = .{ .shade = 2 };
    client.keyboard_window = 0x303;

    try testing.expectEqual(Owner{ .surface = 1 }, client.route(0x101));
    try testing.expectEqual(Owner{ .shade = 2 }, client.route(0x202));
    try testing.expectEqual(Owner{ .shade = 2 }, client.route(0x303));
    try testing.expectEqual(Owner.none, client.route(0x404));
    try testing.expectEqual(Owner.none, client.route(0));

    client.keyboard_owner = .{ .surface = 1 };

    try testing.expectEqual(Owner{ .surface = 1 }, client.route(0x303));
}

test "the keyboard passes to a shown surface before an interactive shade" {
    var client: Client = .{ .state = undefined };

    try testing.expectEqual(Owner.none, client.holder_next());

    client.shades[4] = .{ .window = 0x404 };
    client.shades[5] = .{ .interactive = true, .window = 0x505 };

    try testing.expectEqual(Owner{ .shade = 5 }, client.holder_next());

    client.surfaces[1] = .{ .window = 0x101 };

    try testing.expectEqual(Owner{ .shade = 5 }, client.holder_next());

    client.surfaces[1].mapped = true;

    try testing.expectEqual(Owner{ .surface = 1 }, client.holder_next());
}

test "releasing the holder hands the keyboard on and a bystander changes nothing" {
    var client: Client = .{ .state = undefined };

    client.shades[6] = .{ .interactive = true, .window = 0x606 };
    client.keyboard_owner = .{ .shade = 5 };
    client.keyboard_window = 0x909;

    client.keyboard_release(.{ .shade = 7 });
    client.keyboard_release(.{ .surface = 5 });

    try testing.expectEqual(Owner{ .shade = 5 }, client.keyboard_owner);

    client.keyboard_release(.{ .shade = 5 });

    try testing.expectEqual(Owner{ .shade = 6 }, client.keyboard_owner);
    try testing.expectEqual(@as(u32, 0x909), client.keyboard_window);
    try testing.expectEqual(Owner{ .shade = 6 }, client.route(0x909));
}

test "a shade window overhangs its clip by one column so it never matches a monitor" {
    var client: Client = .{ .state = undefined };

    const monitor = Rect{ .height = 1080, .width = 1920, .x = 1920, .y = 0 };
    const widest = Rect{ .height = 1, .width = std.math.maxInt(u16), .x = 0, .y = 0 };

    try testing.expectEqual(monitor, client.shade_frame(monitor));

    client.shape_opcode = 128;

    const frame = client.shade_frame(monitor);

    try testing.expect(!std.meta.eql(frame, monitor));
    try testing.expectEqual(monitor.x, frame.x);
    try testing.expectEqual(monitor.y, frame.y);
    try testing.expectEqual(monitor.height, frame.height);
    try testing.expectEqual(monitor.width + 1, frame.width);
    try testing.expectEqual(monitor, frame.intersect(monitor));
    try testing.expectEqual(widest, client.shade_frame(widest));
}

fn monitor_info(target: []u8, atom: u32, rect: Rect, outputs: u16, primary: bool) u32 {
    const size = protocol.monitor_info_bytes + @as(u32, outputs) * 4;

    assert(target.len >= size);

    @memset(target[0..size], 0xEE);

    std.mem.writeInt(u32, target[0..4], atom, .little);
    target[4] = @intFromBool(primary);
    std.mem.writeInt(u16, target[6..8], outputs, .little);
    std.mem.writeInt(i16, target[8..10], @intCast(rect.x), .little);
    std.mem.writeInt(i16, target[10..12], @intCast(rect.y), .little);
    std.mem.writeInt(u16, target[12..14], @intCast(rect.width), .little);
    std.mem.writeInt(u16, target[14..16], @intCast(rect.height), .little);

    return size;
}

test "a monitor reply yields every lit monitor and skips the outputs between them" {
    var payload: [256]u8 = undefined;
    var found: [4]MonitorInfo = undefined;

    const left = Rect{ .height = 1080, .width = 1920, .x = 0, .y = 0 };
    const right = Rect{ .height = 1440, .width = 2560, .x = 1920, .y = -120 };

    var length: u32 = 0;

    length += monitor_info(payload[length..], 0xA1, left, 1, false);
    length += monitor_info(payload[length..], 0xA2, .{ .x = 50 }, 0, true);
    length += monitor_info(payload[length..], 0xA3, right, 2, true);

    try testing.expectEqual(@as(u32, 2), parse_monitors(payload[0..length], 3, &found));
    try testing.expectEqual(@as(u32, 0xA1), found[0].atom);
    try testing.expect(std.meta.eql(left, found[0].rect));
    try testing.expect(!found[0].primary);
    try testing.expectEqual(@as(u32, 0xA3), found[1].atom);
    try testing.expect(std.meta.eql(right, found[1].rect));
    try testing.expect(found[1].primary);

    try testing.expectEqual(@as(u32, 1), parse_monitors(payload[0..length], 1, &found));
    try testing.expectEqual(@as(u32, 1), parse_monitors(payload[0 .. length - 4], 3, &found));
    try testing.expectEqual(@as(u32, 1), parse_monitors(payload[0..length], 3, found[0..1]));
    try testing.expectEqual(@as(u32, 0), parse_monitors(payload[0..10], 3, &found));
}

test "a version satisfies a request for itself and anything older" {
    try testing.expect(supports(1, 5, 1, 5));
    try testing.expect(supports(1, 6, 1, 5));
    try testing.expect(supports(2, 0, 1, 5));
    try testing.expect(!supports(1, 4, 1, 5));
    try testing.expect(!supports(0, 9, 1, 1));
}

test "the row budget always advances by at least one row" {
    var client: Client = .{ .state = undefined };

    client.request_bytes_limit = 262140;

    try testing.expect(client.rows_of(1520) > 1);
    try testing.expectEqual(@as(u32, 1), client.rows_of(chunk_bytes_max));
}
