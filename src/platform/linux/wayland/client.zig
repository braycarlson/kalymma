const std = @import("std");

const Display = @import("../display.zig");
const event_module = @import("../../../event.zig");
const geometry = @import("../../geometry.zig");
const interface_module = @import("../../interface.zig");
const monitor_module = @import("../../../monitor.zig");
const protocol = @import("protocol.zig");
const shade_module = @import("../../../shade.zig");
const State = @import("../state.zig");
const surface_module = @import("../../../surface.zig");
const sys = @import("../sys.zig");
const wire = @import("wire.zig");

const assert = std.debug.assert;

const Client = @This();
const Cursor = shade_module.Cursor;
const Event = event_module.Event;
const Monitor = monitor_module.Monitor;
const Rect = geometry.Rect;
const ShadeSlot = interface_module.ShadeSlot;
const Slot = interface_module.Slot;

callback_seen: bool = false,
compositor: u32 = 0,
cursor_shape_device: u32 = 0,
cursor_shape_manager: u32 = 0,
fatal: bool = false,
fill: u32 = 0,
id_next: u32 = 2,
keyboard: u32 = 0,
keyboard_focus: ?Target = null,
layer_shell: u32 = 0,
layer_shell_version: u32 = 0,
output_manager: u32 = 0,
outputs: [monitor_module.count_max]Output = @splat(.{}),
outputs_dirty: bool = false,
pending_callback: u32 = 0,
pointer: u32 = 0,
pointer_focus: ?Target = null,
pointer_serial: u32 = 0,
pointer_x: i32 = 0,
pointer_y: i32 = 0,
reads: [read_bytes_max]u8 = @splat(0),
registry: u32 = 0,
restack_pending: bool = false,
seat: u32 = 0,
seat_capabilities: u32 = 0,
shade_memory: ?[]align(page_align) u8 = null,
shade_pool: u32 = 0,
shade_pool_fd: sys.Fd = -1,
shades: [shade_module.count_max]Shade = @splat(.{}),
shm: u32 = 0,
socket: sys.Fd = -1,
state: *State,
surfaces: [surface_module.count_max]Surface = @splat(.{}),
viewporter: u32 = 0,

pub const Error = Display.Error;

pub const buffers_per_surface: u32 = 2;
pub const pixel_bytes: u32 = 4;
pub const read_bytes_max: u32 = 8192;
pub const roundtrip_attempts_max: u32 = 256;
pub const shade_namespace = "kalymma-shade";
pub const shade_pool_bytes: u32 = shade_module.count_max * pixel_bytes;

const page_align = std.heap.page_size_min;

comptime {
    assert(buffers_per_surface == 2);
    assert(pixel_bytes == 4);
    assert(read_bytes_max >= wire.message_bytes_max);
    assert(roundtrip_attempts_max > 0);
    assert(shade_pool_bytes > 0);
}

const Target = union(enum) {
    shade: u16,
    surface: u16,
};

const Output = struct {
    global: u32 = 0,
    monitor: Monitor = .{},
    output: u32 = 0,
    version: u32 = 0,
    xdg_output: u32 = 0,
};

const Shade = struct {
    buffer: u32 = 0,
    color: u32 = 0,
    configured: bool = false,
    cursor: Cursor = .crosshair,
    interactive: bool = false,
    layer_surface: u32 = 0,
    output: u32 = 0,
    rect: Rect = .{},
    surface: u32 = 0,
    viewport: u32 = 0,
};

const Surface = struct {
    active: u32 = 0,
    busy: [buffers_per_surface]bool = @splat(false),
    buffers: [buffers_per_surface]u32 = @splat(0),
    configured: bool = false,
    layer_surface: u32 = 0,
    mapped: bool = false,
    memory: ?[]align(page_align) u8 = null,
    pool: u32 = 0,
    shm_fd: sys.Fd = -1,
    stride: u32 = 0,
    surface: u32 = 0,
};

pub fn open(client: *Client) Error!void {
    var path_storage: [sys.socket_path_bytes_max]u8 = undefined;

    const path = try resolve_socket(&path_storage);

    client.socket = sys.unix_socket() catch {
        return Error.Unavailable;
    };

    errdefer client.close();

    sys.connect_path(client.socket, path) catch {
        return Error.Unavailable;
    };

    client.fatal = false;
    client.fill = 0;
    client.id_next = 2;

    try client.bind_globals();

    if (client.layer_shell == 0) {
        return Error.Unavailable;
    }

    if (client.compositor == 0) {
        return Error.Unavailable;
    }

    if (client.shm == 0) {
        return Error.Unavailable;
    }

    client.watch_outputs();

    try client.roundtrip();
    try client.bind_seat();

    client.publish_monitors();
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

    client.release_shade_pool();

    if (client.socket >= 0) {
        sys.shutdown(client.socket);
        sys.close(client.socket);
    }

    client.socket = -1;
    client.callback_seen = false;
    client.compositor = 0;
    client.cursor_shape_device = 0;
    client.cursor_shape_manager = 0;
    client.fatal = false;
    client.fill = 0;
    client.keyboard = 0;
    client.keyboard_focus = null;
    client.layer_shell = 0;
    client.layer_shell_version = 0;
    client.id_next = 2;
    client.output_manager = 0;
    client.outputs = @splat(.{});
    client.outputs_dirty = false;
    client.pending_callback = 0;
    client.pointer = 0;
    client.pointer_focus = null;
    client.pointer_serial = 0;
    client.registry = 0;
    client.restack_pending = false;
    client.seat = 0;
    client.seat_capabilities = 0;
    client.shm = 0;
    client.viewporter = 0;

    assert(client.socket < 0);
}

pub fn descriptor(client: *const Client) sys.Fd {
    return client.socket;
}

pub fn is_live(client: *const Client) bool {
    return client.socket >= 0 and !client.fatal;
}

pub fn create(client: *Client, index: u16, slot: *const Slot) Error!void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    if (entry.pool != 0) {
        return;
    }

    const stride = slot.width * 4;
    const frame_bytes = stride * slot.height;
    const total = frame_bytes * buffers_per_surface;

    const fd = sys.memfd("kalymma", total) catch {
        return Error.Failed;
    };

    entry.shm_fd = fd;
    entry.stride = stride;

    entry.memory = sys.map_shared(fd, total) catch {
        client.destroy(index);

        return Error.Failed;
    };

    entry.pool = client.allocate();

    var writer = wire.Writer{};

    writer.begin(client.shm);
    writer.put_u32(entry.pool);
    writer.put_u32(@intCast(total));
    writer.seal(protocol.shm_create_pool);

    client.send_with_fd(&writer, fd) catch {
        client.destroy(index);

        return Error.Failed;
    };

    var slice: u32 = 0;

    while (slice < buffers_per_surface) : (slice += 1) {
        assert(slice < buffers_per_surface);

        entry.buffers[slice] = client.allocate();

        client.create_buffer(entry, slice, slot, frame_bytes) catch {
            client.destroy(index);

            return Error.Failed;
        };
    }

    assert(entry.pool != 0);
}

fn create_buffer(
    client: *Client,
    entry: *Surface,
    slice: u32,
    slot: *const Slot,
    frame_bytes: u32,
) Error!void {
    assert(slice < buffers_per_surface);
    assert(frame_bytes == entry.stride * slot.height);

    var writer = wire.Writer{};

    writer.begin(entry.pool);
    writer.put_u32(entry.buffers[slice]);
    writer.put_u32(frame_bytes * slice);
    writer.put_u32(slot.width);
    writer.put_u32(slot.height);
    writer.put_u32(entry.stride);
    writer.put_u32(protocol.format_argb8888);
    writer.seal(protocol.pool_create_buffer);

    try client.send(&writer);
}

pub fn destroy(client: *Client, index: u16) void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    client.hide(index);

    var slice: u32 = 0;

    while (slice < buffers_per_surface) : (slice += 1) {
        assert(slice < buffers_per_surface);

        if (entry.buffers[slice] != 0) {
            client.request(entry.buffers[slice], protocol.buffer_destroy);
        }
    }

    if (entry.pool != 0) {
        client.request(entry.pool, protocol.pool_destroy);
    }

    if (entry.memory) |memory| {
        sys.unmap(memory);
    }

    if (entry.shm_fd >= 0) {
        sys.close(entry.shm_fd);
    }

    entry.* = .{ .shm_fd = -1 };

    assert(entry.pool == 0);
}

pub fn show(client: *Client, index: u16, slot: *const Slot) Error!void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    if (entry.mapped) {
        return;
    }

    if (entry.pool == 0) {
        return Error.Failed;
    }

    entry.surface = client.allocate();
    entry.layer_surface = client.allocate();
    entry.configured = false;

    try client.create_surface(entry.surface);
    try client.create_layer_surface(entry.layer_surface, entry.surface, 0, slot.get_name());
    try client.configure_layer_surface(entry, slot);

    client.request(entry.surface, protocol.surface_commit);

    try client.roundtrip();

    if (!entry.configured) {
        try client.roundtrip();
    }

    if (!entry.configured) {
        client.hide(index);

        return Error.Failed;
    }

    entry.mapped = true;

    assert(entry.mapped);
}

fn create_surface(client: *Client, surface: u32) Error!void {
    assert(surface >= 2);
    assert(client.compositor != 0);

    var writer = wire.Writer{};

    writer.begin(client.compositor);
    writer.put_u32(surface);
    writer.seal(protocol.compositor_create_surface);

    try client.send(&writer);
}

fn create_layer_surface(
    client: *Client,
    layer_surface: u32,
    surface: u32,
    output: u32,
    namespace: []const u8,
) Error!void {
    assert(layer_surface >= 2);
    assert(surface >= 2);
    assert(layer_surface != surface);

    var writer = wire.Writer{};

    writer.begin(client.layer_shell);
    writer.put_u32(layer_surface);
    writer.put_u32(surface);
    writer.put_u32(output);
    writer.put_u32(protocol.layer_overlay);

    writer.put_string(namespace) catch {
        return Error.Failed;
    };

    writer.seal(protocol.layer_shell_get_layer_surface);

    try client.send(&writer);
}

fn configure_layer_surface(client: *Client, entry: *Surface, slot: *const Slot) Error!void {
    var writer = wire.Writer{};

    writer.begin(entry.layer_surface);
    writer.put_u32(slot.width);
    writer.put_u32(slot.height);
    writer.seal(protocol.layer_surface_set_size);

    try client.send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_u32(protocol.to_anchor_bits(slot.anchor));
    writer.seal(protocol.layer_surface_set_anchor);

    try client.send(&writer);

    const margin: i32 = @intCast(slot.margin);

    writer.begin(entry.layer_surface);
    writer.put_i32(margin);
    writer.put_i32(margin);
    writer.put_i32(margin);
    writer.put_i32(margin);
    writer.seal(protocol.layer_surface_set_margin);

    try client.send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_i32(0);
    writer.seal(protocol.layer_surface_set_exclusive_zone);

    try client.send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_u32(protocol.keyboard_interactivity(client.layer_shell_version));
    writer.seal(protocol.layer_surface_set_keyboard_interactivity);

    try client.send(&writer);
}

pub fn hide(client: *Client, index: u16) void {
    assert(index < surface_module.count_max);

    const entry = &client.surfaces[index];

    if (entry.layer_surface != 0) {
        client.request(entry.layer_surface, protocol.layer_surface_destroy);
    }

    if (entry.surface != 0) {
        client.request(entry.surface, protocol.surface_destroy);
    }

    client.forget(.{ .surface = index });

    entry.busy = @splat(false);
    entry.configured = false;
    entry.layer_surface = 0;
    entry.mapped = false;
    entry.surface = 0;

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

    const memory = entry.memory orelse {
        return Error.Failed;
    };

    const slice = pick_buffer(entry);
    const frame_bytes = entry.stride * slot.height;
    const start = frame_bytes * slice;
    const source = std.mem.sliceAsBytes(pixels);

    if (start + source.len > memory.len) {
        return Error.Failed;
    }

    @memcpy(memory[start..][0..source.len], source);

    entry.active = slice;
    entry.busy[slice] = true;

    var writer = wire.Writer{};

    writer.begin(entry.surface);
    writer.put_u32(entry.buffers[slice]);
    writer.put_i32(0);
    writer.put_i32(0);
    writer.seal(protocol.surface_attach);

    try client.send(&writer);

    writer.begin(entry.surface);
    writer.put_i32(0);
    writer.put_i32(0);
    writer.put_i32(@intCast(slot.width));
    writer.put_i32(@intCast(slot.height));
    writer.seal(protocol.surface_damage);

    try client.send(&writer);

    client.request(entry.surface, protocol.surface_commit);
}

fn pick_buffer(entry: *const Surface) u32 {
    var slice: u32 = 0;

    while (slice < buffers_per_surface) : (slice += 1) {
        assert(slice < buffers_per_surface);

        if (!entry.busy[slice]) return slice;
    }

    const result = (entry.active + 1) % buffers_per_surface;
    assert(result != entry.active);

    return result;
}

pub fn pump(client: *Client) void {
    if (client.socket < 0) {
        return;
    }

    client.read_available() catch {
        client.fatal = true;
    };
}

fn read_available(client: *Client) Error!void {
    const count = sys.recv_discarding_fds(client.socket, client.reads[client.fill..]) catch |err| {
        if (err == sys.Error.WouldBlock) {
            return;
        }

        return Error.Failed;
    };

    if (count == 0) {
        return Error.Failed;
    }

    client.fill += @intCast(count);

    client.consume();
}

fn consume(client: *Client) void {
    client.consume_messages();

    if (client.outputs_dirty) {
        client.outputs_dirty = false;

        client.publish_monitors();
    }
}

fn consume_messages(client: *Client) void {
    var offset: u32 = 0;

    while (client.fill - offset >= wire.header_bytes) {
        var reader = wire.Reader{ .bytes = client.reads[offset..client.fill] };

        const header = reader.read_header() catch {
            break;
        };

        if (header.size > client.fill - offset) {
            break;
        }

        const start = offset + wire.header_bytes;

        var body = wire.Reader{ .bytes = client.reads[start .. offset + header.size] };

        client.handle(header, &body);

        offset += header.size;
    }

    if (offset == 0) {
        if (client.fill == read_bytes_max) client.fill = 0;

        return;
    }

    const remainder = client.fill - offset;

    @memmove(client.reads[0..remainder], client.reads[offset..client.fill]);

    client.fill = remainder;
}

fn handle(client: *Client, header: wire.Header, body: *wire.Reader) void {
    assert(header.size >= wire.header_bytes);
    assert(header.size <= read_bytes_max);
    assert(body.bytes.len == header.size - wire.header_bytes);

    if (header.object == protocol.display_id) {
        if (header.opcode == protocol.display_error) client.fatal = true;

        return;
    }

    if (header.object == client.pending_callback) {
        if (header.opcode == protocol.callback_done) {
            client.callback_seen = true;

            return;
        }
    }

    if (header.object == client.registry) {
        client.handle_registry(header, body);

        return;
    }

    if (header.object == client.seat) {
        if (header.opcode == protocol.seat_capabilities) {
            client.seat_capabilities = body.read_u32() catch 0;

            return;
        }
    }

    if (header.object == client.pointer) {
        client.handle_pointer(header, body);

        return;
    }

    if (header.object == client.keyboard) {
        client.handle_keyboard(header, body);

        return;
    }

    if (client.handle_output_event(header, body)) {
        return;
    }

    if (client.handle_shade_event(header, body)) {
        return;
    }

    client.handle_surface(header, body);
}

fn handle_registry(client: *Client, header: wire.Header, body: *wire.Reader) void {
    assert(header.object == client.registry);

    if (header.opcode == protocol.registry_global_remove) {
        const removed = body.read_u32() catch return;

        client.remove_output(removed);

        return;
    }

    if (header.opcode != protocol.registry_global) {
        return;
    }

    const name = body.read_u32() catch return;
    const interface = body.read_string() catch return;
    const version = body.read_u32() catch return;

    if (client.bind_extension(name, interface, version)) {
        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_compositor)) {
        const bound = @min(version, protocol.version_compositor);

        client.compositor = client.bind(name, interface, bound);

        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_shm)) {
        client.shm = client.bind(name, interface, @min(version, protocol.version_shm));

        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_layer_shell)) {
        client.layer_shell_version = @min(version, protocol.version_layer_shell);
        client.layer_shell = client.bind(name, interface, client.layer_shell_version);

        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_seat)) {
        client.seat = client.bind(name, interface, @min(version, protocol.version_seat));
    }
}

fn bind_extension(client: *Client, name: u32, interface: []const u8, version: u32) bool {
    assert(interface.len > 0);

    if (std.mem.eql(u8, interface, protocol.interface_output)) {
        client.add_output(name, version);

        return true;
    }

    if (std.mem.eql(u8, interface, protocol.interface_output_manager)) {
        const bound = @min(version, protocol.version_output_manager);

        client.output_manager = client.bind(name, interface, bound);

        return true;
    }

    if (std.mem.eql(u8, interface, protocol.interface_viewporter)) {
        const bound = @min(version, protocol.version_viewporter);

        client.viewporter = client.bind(name, interface, bound);

        return true;
    }

    if (std.mem.eql(u8, interface, protocol.interface_cursor_shape_manager)) {
        const bound = @min(version, protocol.version_cursor_shape_manager);

        client.cursor_shape_manager = client.bind(name, interface, bound);

        return true;
    }

    return false;
}

fn handle_pointer(client: *Client, header: wire.Header, body: *wire.Reader) void {
    assert(header.object == client.pointer);

    switch (header.opcode) {
        protocol.pointer_enter => {
            const serial = body.read_u32() catch return;
            const target = body.read_u32() catch return;

            client.pointer_focus = client.target_of(target);
            client.pointer_serial = serial;
            client.pointer_x = body.read_fixed() catch 0;
            client.pointer_y = body.read_fixed() catch 0;

            const point = event_module.Point{ .x = client.pointer_x, .y = client.pointer_y };

            client.point_cursor();
            client.emit(client.pointer_focus, .{ .pointer_move = point });
        },
        protocol.pointer_leave => {
            const focused = client.pointer_focus;

            client.pointer_focus = null;

            client.emit(focused, .{ .pointer_leave = {} });
        },
        protocol.pointer_motion => {
            _ = body.read_u32() catch return;

            client.pointer_x = body.read_fixed() catch 0;
            client.pointer_y = body.read_fixed() catch 0;

            const point = event_module.Point{ .x = client.pointer_x, .y = client.pointer_y };

            client.emit(client.pointer_focus, .{ .pointer_move = point });
        },
        protocol.pointer_button => {
            _ = body.read_u32() catch return;
            _ = body.read_u32() catch return;

            const code = body.read_u32() catch return;
            const pressed = body.read_u32() catch return;

            if (code != protocol.button_left) {
                return;
            }

            const point = event_module.Point{ .x = client.pointer_x, .y = client.pointer_y };

            if (pressed == protocol.button_state_pressed) {
                client.emit(client.pointer_focus, .{ .pointer_down = point });

                return;
            }

            client.emit(client.pointer_focus, .{ .pointer_up = point });

            const focused = client.pointer_focus orelse return;

            switch (focused) {
                .shade => |index| {
                    if (client.shades[index].interactive) client.restack_pending = true;
                },
                .surface => {},
            }
        },
        else => {},
    }
}

pub fn take_restack(client: *Client) bool {
    const result = client.restack_pending;

    client.restack_pending = false;

    assert(!client.restack_pending);

    return result;
}

fn handle_keyboard(client: *Client, header: wire.Header, body: *wire.Reader) void {
    assert(header.object == client.keyboard);

    switch (header.opcode) {
        protocol.keyboard_keymap => {
            return;
        },
        protocol.keyboard_enter => {
            _ = body.read_u32() catch return;

            const target = body.read_u32() catch return;

            client.keyboard_focus = client.target_of(target);
        },
        protocol.keyboard_leave => {
            const focused = client.keyboard_focus;

            client.keyboard_focus = null;

            client.emit(focused, .{ .focus_lost = {} });
        },
        protocol.keyboard_key => {
            _ = body.read_u32() catch return;
            _ = body.read_u32() catch return;

            const code = body.read_u32() catch return;
            const pressed = body.read_u32() catch return;

            if (pressed != protocol.button_state_pressed) {
                return;
            }

            client.emit(client.keyboard_focus, .{ .key_down = protocol.to_key(code) });
        },
        else => {},
    }
}

fn handle_surface(client: *Client, header: wire.Header, body: *wire.Reader) void {
    assert(header.object != protocol.display_id);
    assert(header.object != client.registry);

    var index: u16 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        assert(index < surface_module.count_max);

        const entry = &client.surfaces[index];

        if (entry.layer_surface != 0) {
            if (entry.layer_surface == header.object) {
                client.handle_layer_surface(index, header, body);

                return;
            }
        }

        var slice: u32 = 0;

        while (slice < buffers_per_surface) : (slice += 1) {
            assert(slice < buffers_per_surface);

            if (entry.buffers[slice] == header.object) {
                entry.busy[slice] = false;

                return;
            }
        }
    }
}

fn handle_layer_surface(client: *Client, index: u16, header: wire.Header, body: *wire.Reader) void {
    assert(index < surface_module.count_max);
    assert(header.object == client.surfaces[index].layer_surface);

    const entry = &client.surfaces[index];

    if (header.opcode == protocol.layer_surface_closed) {
        client.emit(.{ .surface = index }, .{ .focus_lost = {} });

        return;
    }

    if (header.opcode != protocol.layer_surface_configure) {
        return;
    }

    const serial = body.read_u32() catch return;

    var writer = wire.Writer{};

    writer.begin(entry.layer_surface);
    writer.put_u32(serial);
    writer.seal(protocol.layer_surface_ack_configure);

    client.send(&writer) catch {
        return;
    };

    entry.configured = true;
}

fn target_of(client: *const Client, object: u32) ?Target {
    if (object == 0) {
        return null;
    }

    var index: u16 = 0;

    while (index < surface_module.count_max) : (index += 1) {
        assert(index < surface_module.count_max);

        if (client.surfaces[index].surface == object) {
            return .{ .surface = index };
        }
    }

    var shade_index: u16 = 0;

    while (shade_index < shade_module.count_max) : (shade_index += 1) {
        assert(shade_index < shade_module.count_max);

        if (client.shades[shade_index].surface == object) {
            return .{ .shade = shade_index };
        }
    }

    return null;
}

fn emit(client: *Client, target: ?Target, input: Event.Input) void {
    const value = target orelse return;

    switch (value) {
        .shade => |index| client.state.publish_shade(index, input),
        .surface => |index| client.state.publish(index, input),
    }
}

fn forget(client: *Client, target: Target) void {
    if (client.pointer_focus) |focused| {
        if (std.meta.eql(focused, target)) client.pointer_focus = null;
    }

    if (client.keyboard_focus) |focused| {
        if (std.meta.eql(focused, target)) client.keyboard_focus = null;
    }

    if (client.pointer_focus) |focused| assert(!std.meta.eql(focused, target));
}

fn point_cursor(client: *Client) void {
    if (client.cursor_shape_device == 0) {
        return;
    }

    const focused = client.pointer_focus orelse return;

    const shape = switch (focused) {
        .shade => |index| cursor_for(&client.shades[index]),
        .surface => protocol.cursor_shape_default,
    };

    var writer = wire.Writer{};

    writer.begin(client.cursor_shape_device);
    writer.put_u32(client.pointer_serial);
    writer.put_u32(shape);
    writer.seal(protocol.cursor_shape_device_set_shape);

    client.send(&writer) catch return;
}

fn cursor_for(entry: *const Shade) u32 {
    if (!entry.interactive) return protocol.cursor_shape_default;

    const result = shape_of(entry.cursor);

    assert(result != 0);

    return result;
}

pub fn shape_of(cursor: Cursor) u32 {
    const result = switch (cursor) {
        .arrow => protocol.cursor_shape_default,
        .crosshair => protocol.cursor_shape_crosshair,
        .move => protocol.cursor_shape_all_scroll,
        .resize_east_west => protocol.cursor_shape_ew_resize,
        .resize_north_south => protocol.cursor_shape_ns_resize,
        .resize_northeast_southwest => protocol.cursor_shape_nesw_resize,
        .resize_northwest_southeast => protocol.cursor_shape_nwse_resize,
    };

    assert(result > 0);

    return result;
}

pub fn shade_cursor(client: *Client, index: u16, cursor: Cursor) Error!void {
    assert(index < shade_module.count_max);

    const entry = &client.shades[index];

    if (entry.buffer == 0) {
        return Error.Failed;
    }

    entry.cursor = cursor;

    assert(entry.cursor == cursor);

    const focused = client.pointer_focus orelse return;

    switch (focused) {
        .shade => |held| if (held == index) client.point_cursor(),
        .surface => {},
    }
}

fn add_output(client: *Client, name: u32, version: u32) void {
    assert(version > 0);

    const index = client.free_output() orelse return;
    const entry = &client.outputs[index];
    const bound = @min(version, protocol.version_output);

    var label: [monitor_module.name_bytes_max]u8 = undefined;

    const fallback: []const u8 = std.mem.print(&label, "output-{d}", .{name}) catch "output";

    entry.* = .{
        .global = name,
        .monitor = Monitor.init(fallback, .{}),
        .output = client.bind(name, protocol.interface_output, bound),
        .version = bound,
    };

    if (client.output_manager != 0) {
        client.watch_output(index);
    }
}

fn free_output(client: *const Client) ?u16 {
    var index: u16 = 0;

    while (index < monitor_module.count_max) : (index += 1) {
        assert(index < monitor_module.count_max);

        if (client.outputs[index].output == 0) {
            return index;
        }
    }

    return null;
}

fn watch_outputs(client: *Client) void {
    if (client.output_manager == 0) {
        return;
    }

    var index: u16 = 0;

    while (index < monitor_module.count_max) : (index += 1) {
        assert(index < monitor_module.count_max);

        if (client.outputs[index].output != 0) {
            if (client.outputs[index].xdg_output == 0) client.watch_output(index);
        }
    }
}

fn watch_output(client: *Client, index: u16) void {
    assert(index < monitor_module.count_max);
    assert(client.output_manager != 0);

    const entry = &client.outputs[index];
    const xdg_output = client.allocate();

    var writer = wire.Writer{};

    writer.begin(client.output_manager);
    writer.put_u32(xdg_output);
    writer.put_u32(entry.output);
    writer.seal(protocol.output_manager_get_output);

    client.send(&writer) catch return;

    entry.xdg_output = xdg_output;
}

fn remove_output(client: *Client, name: u32) void {
    var index: u16 = 0;

    while (index < monitor_module.count_max) : (index += 1) {
        assert(index < monitor_module.count_max);

        const entry = &client.outputs[index];

        if (entry.output == 0) continue;
        if (entry.global != name) continue;

        if (entry.xdg_output != 0) {
            client.request(entry.xdg_output, protocol.xdg_output_destroy);
        }

        if (entry.version >= protocol.version_output_release) {
            client.request(entry.output, protocol.output_release);
        }

        entry.* = .{};
        client.outputs_dirty = true;

        return;
    }
}

fn handle_output_event(client: *Client, header: wire.Header, body: *wire.Reader) bool {
    var index: u16 = 0;

    while (index < monitor_module.count_max) : (index += 1) {
        assert(index < monitor_module.count_max);

        const entry = &client.outputs[index];

        if (entry.output == 0) continue;

        if (entry.output == header.object) {
            client.handle_output(entry, header, body);

            return true;
        }

        if (entry.xdg_output == header.object) {
            client.handle_xdg_output(entry, header, body);

            return true;
        }
    }

    return false;
}

fn handle_output(client: *Client, entry: *Output, header: wire.Header, body: *wire.Reader) void {
    assert(entry.output == header.object);

    switch (header.opcode) {
        protocol.output_done => {
            client.outputs_dirty = true;
        },
        protocol.output_name => {
            const name = body.read_string() catch return;

            entry.monitor = Monitor.init(name, entry.monitor.rect);
        },
        else => {},
    }
}

fn handle_xdg_output(
    client: *Client,
    entry: *Output,
    header: wire.Header,
    body: *wire.Reader,
) void {
    assert(entry.xdg_output == header.object);

    switch (header.opcode) {
        protocol.xdg_output_logical_position => {
            entry.monitor.rect.x = body.read_i32() catch return;
            entry.monitor.rect.y = body.read_i32() catch return;
        },
        protocol.xdg_output_logical_size => {
            entry.monitor.rect.width = body.read_i32() catch return;
            entry.monitor.rect.height = body.read_i32() catch return;
        },
        protocol.xdg_output_done => {
            client.outputs_dirty = true;
        },
        protocol.xdg_output_name => {
            const name = body.read_string() catch return;

            entry.monitor = Monitor.init(name, entry.monitor.rect);
        },
        else => {},
    }
}

fn publish_monitors(client: *Client) void {
    var list = Monitor.List.init();

    for (&client.outputs) |*entry| {
        if (entry.output == 0) continue;
        if (entry.monitor.rect.is_empty()) continue;

        list.append(entry.monitor);
    }

    client.state.set_monitors(&list);
}

fn output_for(client: *const Client, rect: Rect) ?u16 {
    assert(!rect.is_empty());

    var best: ?u16 = null;
    var best_area: i64 = 0;
    var index: u16 = 0;

    while (index < monitor_module.count_max) : (index += 1) {
        assert(index < monitor_module.count_max);

        if (client.outputs[index].output == 0) continue;

        const area = rect.intersect(client.outputs[index].monitor.rect).area();

        if (area > best_area) {
            best = index;
            best_area = area;
        }
    }

    return best;
}

pub fn shade_create(client: *Client, index: u16, slot: *const ShadeSlot) Error!void {
    assert(index < shade_module.count_max);
    assert(slot.used);

    if (client.shades[index].buffer != 0) {
        client.shade_destroy(index);
    }

    if (client.viewporter == 0) {
        return Error.Failed;
    }

    const output_index = client.output_for(slot.rect) orelse return Error.Failed;
    const area = client.outputs[output_index].monitor.rect;
    const entry = &client.shades[index];

    try client.ensure_shade_pool();

    entry.* = .{
        .color = slot.color,
        .cursor = slot.cursor,
        .interactive = slot.interactive,
        .output = client.outputs[output_index].output,
        .rect = slot.rect,
    };

    errdefer client.shade_destroy(index);

    client.write_pixel(index, slot.color);

    try client.build_shade(index, entry);
    try client.arrange_shade(entry, area);
    try client.settle_shade(entry);

    if (!entry.configured) {
        return Error.Failed;
    }
}

fn build_shade(client: *Client, index: u16, entry: *Shade) Error!void {
    assert(index < shade_module.count_max);
    assert(entry.surface == 0);

    entry.buffer = client.allocate();

    try client.create_pixel_buffer(entry.buffer, index);

    entry.surface = client.allocate();

    try client.create_surface(entry.surface);

    if (!entry.interactive) {
        try client.clear_input_region(entry.surface);
    }

    entry.viewport = client.allocate();

    try client.create_viewport(entry.viewport, entry.surface);

    entry.layer_surface = client.allocate();

    try client.create_layer_surface(
        entry.layer_surface,
        entry.surface,
        entry.output,
        shade_namespace,
    );
}

fn arrange_shade(client: *Client, entry: *const Shade, area: Rect) Error!void {
    assert(entry.layer_surface != 0);
    assert(!entry.rect.is_empty());

    var writer = wire.Writer{};

    writer.begin(entry.layer_surface);
    writer.put_u32(@intCast(entry.rect.width));
    writer.put_u32(@intCast(entry.rect.height));
    writer.seal(protocol.layer_surface_set_size);

    try client.send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_u32(protocol.anchor_top | protocol.anchor_left);
    writer.seal(protocol.layer_surface_set_anchor);

    try client.send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_i32(entry.rect.y - area.y);
    writer.put_i32(0);
    writer.put_i32(0);
    writer.put_i32(entry.rect.x - area.x);
    writer.seal(protocol.layer_surface_set_margin);

    try client.send(&writer);
}

fn settle_shade(client: *Client, entry: *Shade) Error!void {
    assert(entry.layer_surface != 0);
    assert(!entry.configured);

    const interactivity = if (entry.interactive)
        protocol.keyboard_interactivity_exclusive
    else
        protocol.keyboard_interactivity_none;

    var writer = wire.Writer{};

    writer.begin(entry.layer_surface);
    writer.put_i32(-1);
    writer.seal(protocol.layer_surface_set_exclusive_zone);

    try client.send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_u32(interactivity);
    writer.seal(protocol.layer_surface_set_keyboard_interactivity);

    try client.send(&writer);

    client.request(entry.surface, protocol.surface_commit);

    try client.roundtrip();

    if (!entry.configured) {
        try client.roundtrip();
    }
}

fn create_pixel_buffer(client: *Client, buffer: u32, index: u16) Error!void {
    assert(buffer >= 2);
    assert(client.shade_pool != 0);

    var writer = wire.Writer{};

    writer.begin(client.shade_pool);
    writer.put_u32(buffer);
    writer.put_u32(@as(u32, index) * pixel_bytes);
    writer.put_u32(1);
    writer.put_u32(1);
    writer.put_u32(pixel_bytes);
    writer.put_u32(protocol.format_argb8888);
    writer.seal(protocol.pool_create_buffer);

    try client.send(&writer);
}

fn clear_input_region(client: *Client, surface: u32) Error!void {
    assert(surface >= 2);
    assert(client.compositor != 0);

    const region = client.allocate();

    var writer = wire.Writer{};

    writer.begin(client.compositor);
    writer.put_u32(region);
    writer.seal(protocol.compositor_create_region);

    try client.send(&writer);

    writer.begin(surface);
    writer.put_u32(region);
    writer.seal(protocol.surface_set_input_region);

    try client.send(&writer);

    client.request(region, protocol.region_destroy);
}

fn create_viewport(client: *Client, viewport: u32, surface: u32) Error!void {
    assert(viewport >= 2);
    assert(client.viewporter != 0);

    var writer = wire.Writer{};

    writer.begin(client.viewporter);
    writer.put_u32(viewport);
    writer.put_u32(surface);
    writer.seal(protocol.viewporter_get_viewport);

    try client.send(&writer);
}

fn ensure_shade_pool(client: *Client) Error!void {
    if (client.shade_pool != 0) {
        return;
    }

    const fd = sys.memfd(shade_namespace, shade_pool_bytes) catch {
        return Error.Failed;
    };

    client.shade_pool_fd = fd;

    client.shade_memory = sys.map_shared(fd, shade_pool_bytes) catch {
        client.release_shade_pool();

        return Error.Failed;
    };

    const pool = client.allocate();

    var writer = wire.Writer{};

    writer.begin(client.shm);
    writer.put_u32(pool);
    writer.put_u32(shade_pool_bytes);
    writer.seal(protocol.shm_create_pool);

    client.send_with_fd(&writer, fd) catch {
        client.release_shade_pool();

        return Error.Failed;
    };

    client.shade_pool = pool;

    assert(client.shade_pool != 0);
}

fn release_shade_pool(client: *Client) void {
    if (client.shade_pool != 0) {
        client.request(client.shade_pool, protocol.pool_destroy);
    }

    if (client.shade_memory) |memory| {
        sys.unmap(memory);
    }

    if (client.shade_pool_fd >= 0) {
        sys.close(client.shade_pool_fd);
    }

    client.shade_memory = null;
    client.shade_pool = 0;
    client.shade_pool_fd = -1;
}

fn write_pixel(client: *Client, index: u16, color: u32) void {
    assert(index < shade_module.count_max);

    const memory = client.shade_memory orelse return;
    const offset = @as(u32, index) * pixel_bytes;

    std.mem.writeInt(u32, memory[offset..][0..4], shade_module.premultiply(color), .little);
}

pub fn shade_destroy(client: *Client, index: u16) void {
    assert(index < shade_module.count_max);

    const entry = &client.shades[index];

    client.release_shade_surface(index);

    if (entry.buffer != 0) {
        client.request(entry.buffer, protocol.buffer_destroy);
    }

    entry.* = .{};

    assert(entry.surface == 0);
}

fn release_shade_surface(client: *Client, index: u16) void {
    assert(index < shade_module.count_max);

    const entry = &client.shades[index];

    if (entry.layer_surface != 0) {
        client.request(entry.layer_surface, protocol.layer_surface_destroy);
    }

    if (entry.viewport != 0) {
        client.request(entry.viewport, protocol.viewport_destroy);
    }

    if (entry.surface != 0) {
        client.request(entry.surface, protocol.surface_destroy);
    }

    client.forget(.{ .shade = index });

    entry.configured = false;
    entry.layer_surface = 0;
    entry.surface = 0;
    entry.viewport = 0;
}

pub fn shade_fill(client: *Client, index: u16, color: u32) Error!void {
    assert(index < shade_module.count_max);

    const entry = &client.shades[index];

    if (entry.buffer == 0) {
        return Error.Failed;
    }

    entry.color = color;

    client.write_pixel(index, color);

    if (!entry.configured) {
        return;
    }

    try client.paint_shade(entry);

    client.request(entry.surface, protocol.surface_commit);
}

pub fn shade_place(client: *Client, index: u16, rect: Rect) Error!void {
    assert(index < shade_module.count_max);
    assert(!rect.is_empty());

    const entry = &client.shades[index];

    if (entry.buffer == 0) {
        return Error.Failed;
    }

    const output_index = client.output_for(rect) orelse return Error.Failed;

    if (client.outputs[output_index].output != entry.output) {
        const slot = ShadeSlot{
            .color = entry.color,
            .interactive = entry.interactive,
            .rect = rect,
            .used = true,
        };

        try client.shade_create(index, &slot);

        return;
    }

    if (entry.layer_surface == 0) {
        return Error.Failed;
    }

    entry.rect = rect;

    try client.arrange_shade(entry, client.outputs[output_index].monitor.rect);

    if (entry.configured) {
        try client.paint_shade(entry);
    }

    client.request(entry.surface, protocol.surface_commit);
}

fn handle_shade_event(client: *Client, header: wire.Header, body: *wire.Reader) bool {
    var index: u16 = 0;

    while (index < shade_module.count_max) : (index += 1) {
        assert(index < shade_module.count_max);

        const entry = &client.shades[index];

        if (entry.layer_surface == 0) continue;
        if (entry.layer_surface != header.object) continue;

        client.handle_shade_layer_surface(index, header, body);

        return true;
    }

    return false;
}

fn handle_shade_layer_surface(
    client: *Client,
    index: u16,
    header: wire.Header,
    body: *wire.Reader,
) void {
    assert(index < shade_module.count_max);
    assert(header.object == client.shades[index].layer_surface);

    const entry = &client.shades[index];

    if (header.opcode == protocol.layer_surface_closed) {
        client.release_shade_surface(index);

        return;
    }

    if (header.opcode != protocol.layer_surface_configure) {
        return;
    }

    const serial = body.read_u32() catch return;

    var writer = wire.Writer{};

    writer.begin(entry.layer_surface);
    writer.put_u32(serial);
    writer.seal(protocol.layer_surface_ack_configure);

    client.send(&writer) catch return;

    entry.configured = true;

    client.paint_shade(entry) catch return;

    client.request(entry.surface, protocol.surface_commit);
}

fn paint_shade(client: *Client, entry: *const Shade) Error!void {
    assert(entry.configured);
    assert(entry.viewport != 0);

    var writer = wire.Writer{};

    writer.begin(entry.viewport);
    writer.put_i32(entry.rect.width);
    writer.put_i32(entry.rect.height);
    writer.seal(protocol.viewport_set_destination);

    try client.send(&writer);

    writer.begin(entry.surface);
    writer.put_u32(entry.buffer);
    writer.put_i32(0);
    writer.put_i32(0);
    writer.seal(protocol.surface_attach);

    try client.send(&writer);

    writer.begin(entry.surface);
    writer.put_i32(0);
    writer.put_i32(0);
    writer.put_i32(entry.rect.width);
    writer.put_i32(entry.rect.height);
    writer.seal(protocol.surface_damage);

    try client.send(&writer);
}

fn bind_globals(client: *Client) Error!void {
    client.registry = client.allocate();

    var writer = wire.Writer{};

    writer.begin(protocol.display_id);
    writer.put_u32(client.registry);
    writer.seal(protocol.display_get_registry);

    try client.send(&writer);
    try client.roundtrip();
}

fn bind_seat(client: *Client) Error!void {
    if (client.seat == 0) {
        return;
    }

    try client.roundtrip();

    if (client.seat_capabilities & protocol.seat_capability_pointer != 0) {
        client.pointer = client.allocate();

        var writer = wire.Writer{};

        writer.begin(client.seat);
        writer.put_u32(client.pointer);
        writer.seal(protocol.seat_get_pointer);

        try client.send(&writer);
        try client.bind_cursor_shape();
    }

    if (client.seat_capabilities & protocol.seat_capability_keyboard != 0) {
        client.keyboard = client.allocate();

        var writer = wire.Writer{};

        writer.begin(client.seat);
        writer.put_u32(client.keyboard);
        writer.seal(protocol.seat_get_keyboard);

        try client.send(&writer);
    }
}

fn bind_cursor_shape(client: *Client) Error!void {
    assert(client.pointer != 0);

    if (client.cursor_shape_manager == 0) {
        return;
    }

    client.cursor_shape_device = client.allocate();

    var writer = wire.Writer{};

    writer.begin(client.cursor_shape_manager);
    writer.put_u32(client.cursor_shape_device);
    writer.put_u32(client.pointer);
    writer.seal(protocol.cursor_shape_manager_get_pointer);

    try client.send(&writer);
}

fn bind(client: *Client, name: u32, interface: []const u8, version: u32) u32 {
    assert(interface.len > 0);
    assert(std.mem.findScalar(u8, interface, 0) == null);

    assert(version <= @max(
        protocol.version_compositor,
        protocol.version_cursor_shape_manager,
        protocol.version_layer_shell,
        protocol.version_output,
        protocol.version_output_manager,
        protocol.version_seat,
        protocol.version_shm,
        protocol.version_viewporter,
    ));

    const id = client.allocate();

    var writer = wire.Writer{};

    writer.begin(client.registry);
    writer.put_u32(name);

    writer.put_string(interface) catch {
        return 0;
    };

    writer.put_u32(version);
    writer.put_u32(id);
    writer.seal(protocol.registry_bind);

    client.send(&writer) catch {
        return 0;
    };

    return id;
}

fn allocate(client: *Client) u32 {
    const result = client.id_next;

    client.id_next += 1;

    assert(result >= 2);

    return result;
}

fn request(client: *Client, object: u32, opcode: u16) void {
    assert(object >= 1);

    var writer = wire.Writer{};

    writer.begin(object);
    writer.seal(opcode);

    client.send(&writer) catch {
        return;
    };
}

fn send(client: *Client, writer: *wire.Writer) Error!void {
    sys.write_all(client.socket, writer.finish()) catch {
        client.fatal = true;

        return Error.Failed;
    };
}

fn send_with_fd(client: *Client, writer: *wire.Writer, payload: sys.Fd) Error!void {
    assert(payload >= 0);
    assert(payload != client.socket);

    sys.send_with_fd(client.socket, writer.finish(), payload) catch {
        client.fatal = true;

        return Error.Failed;
    };
}

pub fn roundtrip(client: *Client) Error!void {
    const id = client.allocate();

    var writer = wire.Writer{};

    writer.begin(protocol.display_id);
    writer.put_u32(id);
    writer.seal(protocol.display_sync);

    client.pending_callback = id;
    client.callback_seen = false;

    try client.send(&writer);

    var attempts: u32 = 0;

    while (attempts < roundtrip_attempts_max) : (attempts += 1) {
        if (client.callback_seen) {
            break;
        }

        assert(attempts < roundtrip_attempts_max);

        client.blocking_read() catch {
            return Error.Failed;
        };
    }

    if (!client.callback_seen) {
        return Error.Failed;
    }
}

fn blocking_read(client: *Client) Error!void {
    var fds = [_]std.os.linux.pollfd{
        .{ .fd = client.socket, .events = poll_in, .revents = 0 },
    };

    const ready = sys.wait(&fds, roundtrip_timeout_ms) catch {
        return Error.Failed;
    };

    if (ready == 0) {
        return Error.Failed;
    }

    try client.read_available();
}

pub const poll_in: i16 = 1;
pub const roundtrip_timeout_ms: i32 = 2000;

pub fn resolve_socket(storage: []u8) Error![]const u8 {
    assert(storage.len > 0);

    var environ: sys.Environ = .{};

    environ.load();

    const display = environ.get("WAYLAND_DISPLAY") orelse "wayland-0";

    if (std.mem.startsWith(u8, display, "/")) {
        if (display.len > storage.len) {
            return Error.Unavailable;
        }

        @memcpy(storage[0..display.len], display);

        return storage[0..display.len];
    }

    const directory = environ.get("XDG_RUNTIME_DIR") orelse {
        return Error.Unavailable;
    };

    const result = std.mem.print(storage, "{s}/{s}", .{ directory, display }) catch {
        return Error.Unavailable;
    };

    return result;
}

const testing = std.testing;

test "each cursor maps to a distinct cursor shape and the move cursor to the four way arrow" {
    const cursors = std.enums.values(Cursor);

    for (cursors, 0..) |cursor, position| {
        for (cursors[position + 1 ..]) |other| {
            try testing.expect(shape_of(cursor) != shape_of(other));
        }
    }

    try testing.expectEqual(protocol.cursor_shape_all_scroll, shape_of(.move));
    try testing.expectEqual(protocol.cursor_shape_default, shape_of(.arrow));

    const passive = Shade{ .cursor = .move, .interactive = false };

    try testing.expectEqual(protocol.cursor_shape_default, cursor_for(&passive));
}

test "a socket path is built from the runtime directory and the display name" {
    var storage: [sys.socket_path_bytes_max]u8 = undefined;

    const resolved = resolve_socket(&storage) catch {
        return error.SkipZigTest;
    };

    try testing.expect(resolved.len > 0);
    try testing.expect(std.mem.findScalar(u8, resolved, '/') != null);
}

test "a storage buffer too small for the socket path is refused" {
    var storage: [8]u8 = undefined;

    try testing.expectError(Error.Unavailable, resolve_socket(&storage));
}

test "a shade sits on the output it overlaps most" {
    var client: Client = .{ .state = undefined };

    const left = Rect{ .height = 1080, .width = 1920 };
    const right = Rect{ .height = 1440, .width = 2560, .x = 1920 };

    client.outputs[0] = .{ .monitor = Monitor.init("left", left), .output = 7 };
    client.outputs[2] = .{ .monitor = Monitor.init("right", right), .output = 9 };

    const inside = Rect{ .height = 10, .width = 10, .x = 5 };
    const across = Rect{ .height = 500, .width = 600, .x = 1800 };
    const edge = Rect{ .height = 500, .width = 200, .x = 1800 };
    const away = Rect{ .height = 10, .width = 10, .x = 9000 };

    try testing.expectEqual(@as(?u16, 0), client.output_for(inside));
    try testing.expectEqual(@as(?u16, 2), client.output_for(across));
    try testing.expectEqual(@as(?u16, 0), client.output_for(edge));
    try testing.expectEqual(@as(?u16, null), client.output_for(away));
}

test "a released target loses pointer and keyboard focus and no other" {
    var client: Client = .{ .state = undefined };

    client.pointer_focus = .{ .shade = 3 };
    client.keyboard_focus = .{ .surface = 3 };

    client.forget(.{ .shade = 3 });

    try testing.expect(client.pointer_focus == null);
    try testing.expect(std.meta.eql(client.keyboard_focus.?, Target{ .surface = 3 }));
}

test "buffer selection avoids the descriptor the compositor still holds" {
    var entry = Surface{ .shm_fd = -1 };

    try testing.expectEqual(@as(u32, 0), pick_buffer(&entry));

    entry.busy[0] = true;

    try testing.expectEqual(@as(u32, 1), pick_buffer(&entry));

    entry.busy[1] = true;
    entry.active = 1;

    try testing.expectEqual(@as(u32, 0), pick_buffer(&entry));
}
