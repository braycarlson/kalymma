const std = @import("std");

const contract = @import("../../contract.zig");
const protocol = @import("protocol.zig");
const seam = @import("../seam.zig");
const state = @import("../state.zig");
const sys = @import("../sys.zig");
const wire = @import("wire.zig");

const assert = std.debug.assert;

const Slot = contract.Slot;

pub const Error = seam.Error;

pub const buffers_per_surface: u32 = 2;
pub const read_bytes_max: u32 = 8192;
pub const roundtrip_attempts_max: u32 = 256;
pub const socket_path_bytes_max: u32 = 128;
pub const surfaces_max: u32 = contract.surfaces_max;

const page_align = std.heap.page_size_min;

comptime {
    assert(buffers_per_surface == 2);
    assert(read_bytes_max >= wire.message_bytes_max);
    assert(roundtrip_attempts_max > 0);
    assert(socket_path_bytes_max > 0);
}

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

var callback_seen: bool = false;
var compositor: u32 = 0;
var fatal: bool = false;
var fill: u32 = 0;
var keyboard: u32 = 0;
var keyboard_focus: ?u16 = null;
var layer_shell: u32 = 0;
var next_id: u32 = 2;
var pending_callback: u32 = 0;
var pointer: u32 = 0;
var pointer_focus: ?u16 = null;
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var reads: [read_bytes_max]u8 = @splat(0);
var registry: u32 = 0;
var seat: u32 = 0;
var seat_capabilities: u32 = 0;
var shm: u32 = 0;
var socket: sys.Fd = -1;
var surfaces: [surfaces_max]Surface = @splat(.{});

pub fn open() Error!void {
    var path_storage: [socket_path_bytes_max]u8 = undefined;

    const path = try resolve_socket(&path_storage);

    socket = sys.unix_socket() catch {
        return Error.Unavailable;
    };

    errdefer close();

    sys.connect_path(socket, path) catch {
        return Error.Unavailable;
    };

    fatal = false;
    fill = 0;
    next_id = 2;

    try bind_globals();

    if (layer_shell == 0 or compositor == 0 or shm == 0) {
        return Error.Unavailable;
    }

    try bind_seat();
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

    socket = -1;
    callback_seen = false;
    compositor = 0;
    fatal = false;
    fill = 0;
    keyboard = 0;
    keyboard_focus = null;
    layer_shell = 0;
    next_id = 2;
    pending_callback = 0;
    pointer = 0;
    pointer_focus = null;
    registry = 0;
    seat = 0;
    seat_capabilities = 0;
    shm = 0;

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

    if (entry.pool != 0) {
        return;
    }

    const stride = slot.width * slot.scale * 4;
    const frame_bytes = stride * slot.height * slot.scale;
    const total = frame_bytes * buffers_per_surface;

    const fd = sys.memfd("kalymma", total) catch {
        return Error.Failed;
    };

    entry.shm_fd = fd;
    entry.stride = stride;

    entry.memory = sys.map_shared(fd, total) catch {
        destroy(index);

        return Error.Failed;
    };

    entry.pool = allocate();

    var writer = wire.Writer{};

    writer.begin(shm);
    writer.put_u32(entry.pool);
    writer.put_u32(@intCast(total));
    writer.seal(protocol.shm_create_pool);

    send_with_fd(&writer, fd) catch {
        destroy(index);

        return Error.Failed;
    };

    var slice: u32 = 0;

    while (slice < buffers_per_surface) : (slice += 1) {
        assert(slice < buffers_per_surface);

        entry.buffers[slice] = allocate();

        create_buffer(entry, slice, slot, frame_bytes) catch {
            destroy(index);

            return Error.Failed;
        };
    }

    assert(entry.pool != 0);
}

fn create_buffer(entry: *Surface, slice: u32, slot: *const Slot, frame_bytes: u32) Error!void {
    var writer = wire.Writer{};

    writer.begin(entry.pool);
    writer.put_u32(entry.buffers[slice]);
    writer.put_u32(frame_bytes * slice);
    writer.put_u32(slot.width * slot.scale);
    writer.put_u32(slot.height * slot.scale);
    writer.put_u32(entry.stride);
    writer.put_u32(protocol.format_argb8888);
    writer.seal(protocol.pool_create_buffer);

    try send(&writer);
}

pub fn destroy(index: u16) void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    hide(index);

    var slice: u32 = 0;

    while (slice < buffers_per_surface) : (slice += 1) {
        assert(slice < buffers_per_surface);

        if (entry.buffers[slice] != 0) {
            request(entry.buffers[slice], protocol.buffer_destroy);
        }
    }

    if (entry.pool != 0) {
        request(entry.pool, protocol.pool_destroy);
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

pub fn show(index: u16, slot: *const Slot) Error!void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (entry.mapped) {
        return;
    }

    if (entry.pool == 0) {
        return Error.Failed;
    }

    entry.surface = allocate();
    entry.layer_surface = allocate();
    entry.configured = false;

    try create_surface(entry);
    try create_layer_surface(entry, slot);
    try configure_layer_surface(entry, slot);

    request(entry.surface, protocol.surface_commit);

    try roundtrip();

    if (!entry.configured) {
        try roundtrip();
    }

    if (!entry.configured) {
        hide(index);

        return Error.Failed;
    }

    entry.mapped = true;

    assert(entry.mapped);
}

fn create_surface(entry: *Surface) Error!void {
    var writer = wire.Writer{};

    writer.begin(compositor);
    writer.put_u32(entry.surface);
    writer.seal(protocol.compositor_create_surface);

    try send(&writer);
}

fn create_layer_surface(entry: *Surface, slot: *const Slot) Error!void {
    var writer = wire.Writer{};

    writer.begin(layer_shell);
    writer.put_u32(entry.layer_surface);
    writer.put_u32(entry.surface);
    writer.put_u32(0);
    writer.put_u32(protocol.layer_overlay);

    writer.put_string(slot.get_name()) catch {
        return Error.Failed;
    };

    writer.seal(protocol.layer_shell_get_layer_surface);

    try send(&writer);
}

fn configure_layer_surface(entry: *Surface, slot: *const Slot) Error!void {
    var writer = wire.Writer{};

    writer.begin(entry.layer_surface);
    writer.put_u32(slot.width);
    writer.put_u32(slot.height);
    writer.seal(protocol.layer_surface_set_size);

    try send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_u32(protocol.to_anchor_bits(slot.anchor));
    writer.seal(protocol.layer_surface_set_anchor);

    try send(&writer);

    const margin: i32 = @intCast(slot.margin);

    writer.begin(entry.layer_surface);
    writer.put_i32(margin);
    writer.put_i32(margin);
    writer.put_i32(margin);
    writer.put_i32(margin);
    writer.seal(protocol.layer_surface_set_margin);

    try send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_i32(0);
    writer.seal(protocol.layer_surface_set_exclusive_zone);

    try send(&writer);

    writer.begin(entry.layer_surface);
    writer.put_u32(protocol.keyboard_interactivity_on_demand);
    writer.seal(protocol.layer_surface_set_keyboard_interactivity);

    try send(&writer);
}

pub fn hide(index: u16) void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (entry.layer_surface != 0) {
        request(entry.layer_surface, protocol.layer_surface_destroy);
    }

    if (entry.surface != 0) {
        request(entry.surface, protocol.surface_destroy);
    }

    if (pointer_focus) |focused| {
        if (focused == index) pointer_focus = null;
    }

    if (keyboard_focus) |focused| {
        if (focused == index) keyboard_focus = null;
    }

    entry.busy = @splat(false);
    entry.configured = false;
    entry.layer_surface = 0;
    entry.mapped = false;
    entry.surface = 0;

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

    const memory = entry.memory orelse {
        return Error.Failed;
    };

    const slice = pick_buffer(entry);
    const frame_bytes = entry.stride * slot.height * slot.scale;
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

    try send(&writer);

    writer.begin(entry.surface);
    writer.put_i32(0);
    writer.put_i32(0);
    writer.put_i32(@intCast(slot.width));
    writer.put_i32(@intCast(slot.height));
    writer.seal(protocol.surface_damage);

    try send(&writer);

    request(entry.surface, protocol.surface_commit);
}

fn pick_buffer(entry: *const Surface) u32 {
    var slice: u32 = 0;

    while (slice < buffers_per_surface) : (slice += 1) {
        assert(slice < buffers_per_surface);

        if (!entry.busy[slice]) return slice;
    }

    return (entry.active + 1) % buffers_per_surface;
}

pub fn pump() void {
    if (socket < 0) {
        return;
    }

    read_available() catch {
        fatal = true;
    };
}

fn read_available() Error!void {
    const count = sys.recv_discarding_fds(socket, reads[fill..]) catch |err| {
        if (err == sys.Error.WouldBlock) {
            return;
        }

        return Error.Failed;
    };

    if (count == 0) {
        return Error.Failed;
    }

    fill += @intCast(count);

    consume();
}

fn consume() void {
    var offset: u32 = 0;

    while (fill - offset >= wire.header_bytes) {
        var reader = wire.Reader{ .bytes = reads[offset..fill] };

        const header = reader.read_header() catch {
            break;
        };

        if (header.size > fill - offset) {
            break;
        }

        const start = offset + wire.header_bytes;

        var body = wire.Reader{ .bytes = reads[start .. offset + header.size] };

        handle(header, &body);

        offset += header.size;
    }

    if (offset == 0) {
        if (fill == read_bytes_max) fill = 0;

        return;
    }

    const remainder = fill - offset;

    std.mem.copyForwards(u8, reads[0..remainder], reads[offset..fill]);

    fill = remainder;
}

fn handle(header: wire.Header, body: *wire.Reader) void {
    if (header.object == protocol.display_id) {
        if (header.opcode == protocol.display_error) fatal = true;

        return;
    }

    if (header.object == pending_callback and header.opcode == protocol.callback_done) {
        callback_seen = true;

        return;
    }

    if (header.object == registry) {
        handle_registry(header, body);

        return;
    }

    if (header.object == seat and header.opcode == protocol.seat_capabilities) {
        seat_capabilities = body.read_u32() catch 0;

        return;
    }

    if (header.object == pointer) {
        handle_pointer(header, body);

        return;
    }

    if (header.object == keyboard) {
        handle_keyboard(header, body);

        return;
    }

    handle_surface(header, body);
}

fn handle_registry(header: wire.Header, body: *wire.Reader) void {
    if (header.opcode != protocol.registry_global) {
        return;
    }

    const name = body.read_u32() catch return;
    const interface = body.read_string() catch return;
    const version = body.read_u32() catch return;

    if (std.mem.eql(u8, interface, protocol.interface_compositor)) {
        compositor = bind(name, interface, @min(version, protocol.version_compositor));

        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_shm)) {
        shm = bind(name, interface, @min(version, protocol.version_shm));

        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_layer_shell)) {
        layer_shell = bind(name, interface, @min(version, protocol.version_layer_shell));

        return;
    }

    if (std.mem.eql(u8, interface, protocol.interface_seat)) {
        seat = bind(name, interface, @min(version, protocol.version_seat));
    }
}

fn handle_pointer(header: wire.Header, body: *wire.Reader) void {
    switch (header.opcode) {
        protocol.pointer_enter => {
            _ = body.read_u32() catch return;

            const target = body.read_u32() catch return;

            pointer_focus = index_of_surface(target);
            pointer_x = body.read_fixed() catch 0;
            pointer_y = body.read_fixed() catch 0;

            emit(pointer_focus, .{ .pointer_move = .{ .x = pointer_x, .y = pointer_y } });
        },
        protocol.pointer_leave => {
            const focused = pointer_focus;

            pointer_focus = null;

            emit(focused, .{ .pointer_leave = {} });
        },
        protocol.pointer_motion => {
            _ = body.read_u32() catch return;

            pointer_x = body.read_fixed() catch 0;
            pointer_y = body.read_fixed() catch 0;

            emit(pointer_focus, .{ .pointer_move = .{ .x = pointer_x, .y = pointer_y } });
        },
        protocol.pointer_button => {
            _ = body.read_u32() catch return;
            _ = body.read_u32() catch return;

            const code = body.read_u32() catch return;
            const pressed = body.read_u32() catch return;

            if (code != protocol.button_left) {
                return;
            }

            const point = contract.Point{ .x = pointer_x, .y = pointer_y };

            if (pressed == protocol.button_state_pressed) {
                emit(pointer_focus, .{ .pointer_down = point });

                return;
            }

            emit(pointer_focus, .{ .pointer_up = point });
        },
        else => {},
    }
}

fn handle_keyboard(header: wire.Header, body: *wire.Reader) void {
    switch (header.opcode) {
        protocol.keyboard_keymap => {
            return;
        },
        protocol.keyboard_enter => {
            _ = body.read_u32() catch return;

            const target = body.read_u32() catch return;

            keyboard_focus = index_of_surface(target);
        },
        protocol.keyboard_leave => {
            const focused = keyboard_focus;

            keyboard_focus = null;

            emit(focused, .{ .focus_lost = {} });
        },
        protocol.keyboard_key => {
            _ = body.read_u32() catch return;
            _ = body.read_u32() catch return;

            const code = body.read_u32() catch return;
            const pressed = body.read_u32() catch return;

            if (pressed != protocol.button_state_pressed) {
                return;
            }

            emit(keyboard_focus, .{ .key_down = protocol.to_key(code) });
        },
        else => {},
    }
}

fn handle_surface(header: wire.Header, body: *wire.Reader) void {
    var index: u16 = 0;

    while (index < surfaces_max) : (index += 1) {
        assert(index < surfaces_max);

        const entry = &surfaces[index];

        if (entry.layer_surface != 0 and entry.layer_surface == header.object) {
            handle_layer_surface(index, header, body);

            return;
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

fn handle_layer_surface(index: u16, header: wire.Header, body: *wire.Reader) void {
    assert(index < surfaces_max);

    const entry = &surfaces[index];

    if (header.opcode == protocol.layer_surface_closed) {
        emit(index, .{ .focus_lost = {} });

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

    send(&writer) catch {
        return;
    };

    entry.configured = true;
}

fn index_of_surface(object: u32) ?u16 {
    var index: u16 = 0;

    while (index < surfaces_max) : (index += 1) {
        assert(index < surfaces_max);

        if (surfaces[index].surface != 0 and surfaces[index].surface == object) return index;
    }

    return null;
}

fn emit(index: ?u16, input: contract.InputEvent) void {
    const target = index orelse return;

    state.publish(target, input);
}

fn bind_globals() Error!void {
    registry = allocate();

    var writer = wire.Writer{};

    writer.begin(protocol.display_id);
    writer.put_u32(registry);
    writer.seal(protocol.display_get_registry);

    try send(&writer);
    try roundtrip();
}

fn bind_seat() Error!void {
    if (seat == 0) {
        return;
    }

    try roundtrip();

    if (seat_capabilities & protocol.seat_capability_pointer != 0) {
        pointer = allocate();

        var writer = wire.Writer{};

        writer.begin(seat);
        writer.put_u32(pointer);
        writer.seal(protocol.seat_get_pointer);

        try send(&writer);
    }

    if (seat_capabilities & protocol.seat_capability_keyboard != 0) {
        keyboard = allocate();

        var writer = wire.Writer{};

        writer.begin(seat);
        writer.put_u32(keyboard);
        writer.seal(protocol.seat_get_keyboard);

        try send(&writer);
    }
}

fn bind(name: u32, interface: []const u8, version: u32) u32 {
    const id = allocate();

    var writer = wire.Writer{};

    writer.begin(registry);
    writer.put_u32(name);

    writer.put_string(interface) catch {
        return 0;
    };

    writer.put_u32(version);
    writer.put_u32(id);
    writer.seal(protocol.registry_bind);

    send(&writer) catch {
        return 0;
    };

    return id;
}

fn allocate() u32 {
    const result = next_id;

    next_id += 1;

    assert(result >= 2);

    return result;
}

fn request(object: u32, opcode: u16) void {
    assert(object >= 1);

    var writer = wire.Writer{};

    writer.begin(object);
    writer.seal(opcode);

    send(&writer) catch {
        return;
    };
}

fn send(writer: *wire.Writer) Error!void {
    sys.write_all(socket, writer.finish()) catch {
        fatal = true;

        return Error.Failed;
    };
}

fn send_with_fd(writer: *wire.Writer, payload: sys.Fd) Error!void {
    sys.send_with_fd(socket, writer.finish(), payload) catch {
        fatal = true;

        return Error.Failed;
    };
}

pub fn roundtrip() Error!void {
    const id = allocate();

    var writer = wire.Writer{};

    writer.begin(protocol.display_id);
    writer.put_u32(id);
    writer.seal(protocol.display_sync);

    pending_callback = id;
    callback_seen = false;

    try send(&writer);

    var attempts: u32 = 0;

    while (!callback_seen and attempts < roundtrip_attempts_max) : (attempts += 1) {
        assert(attempts < roundtrip_attempts_max);

        blocking_read() catch {
            return Error.Failed;
        };
    }

    if (!callback_seen) {
        return Error.Failed;
    }
}

fn blocking_read() Error!void {
    var fds = [_]std.os.linux.pollfd{
        .{ .fd = socket, .events = poll_in, .revents = 0 },
    };

    const ready = sys.wait(&fds, roundtrip_timeout_ms) catch {
        return Error.Failed;
    };

    if (ready == 0) {
        return Error.Failed;
    }

    try read_available();
}

pub const poll_in: i16 = 1;
pub const roundtrip_timeout_ms: i32 = 2000;

pub fn resolve_socket(storage: []u8) Error![]const u8 {
    assert(storage.len > 0);

    const display = sys.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

    if (display.len > 0 and display[0] == '/') {
        if (display.len > storage.len) {
            return Error.Unavailable;
        }

        @memcpy(storage[0..display.len], display);

        return storage[0..display.len];
    }

    const directory = sys.getenv("XDG_RUNTIME_DIR") orelse {
        return Error.Unavailable;
    };

    const result = std.fmt.bufPrint(storage, "{s}/{s}", .{ directory, display }) catch {
        return Error.Unavailable;
    };

    return result;
}

const testing = std.testing;

test "a socket path is built from the runtime directory and the display name" {
    var storage: [socket_path_bytes_max]u8 = undefined;

    const resolved = resolve_socket(&storage) catch {
        return error.SkipZigTest;
    };

    try testing.expect(resolved.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, resolved, '/') != null);
}

test "a storage buffer too small for the socket path is refused" {
    var storage: [8]u8 = undefined;

    try testing.expectError(Error.Unavailable, resolve_socket(&storage));
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
