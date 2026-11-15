const std = @import("std");

const geometry = @import("../geometry.zig");
const interface = @import("../interface.zig");
const shade_module = @import("../../shade.zig");
const State = @import("state.zig");
const surface_module = @import("../../surface.zig");
const sys = @import("sys.zig");
const WaylandClient = @import("wayland.zig").Client;
const X11Client = @import("x11.zig").Client;

const assert = std.debug.assert;

const Cursor = shade_module.Cursor;
const Display = @This();
const Rect = geometry.Rect;
const ShadeSlot = interface.ShadeSlot;
const Slot = interface.Slot;

active: Server,
wayland: WaylandClient,
x11: X11Client,

pub const Error = error{ Failed, Unavailable };

pub const Server = enum(u8) {
    none = 0,
    wayland = 1,
    x11 = 2,
};

comptime {
    assert_display(WaylandClient);
    assert_display(X11Client);
}

pub fn init(display: *Display, state: *State) void {
    display.* = .{
        .active = .none,
        .wayland = .{ .state = state },
        .x11 = .{ .state = state },
    };

    assert(display.active == .none);
    assert(display.wayland.state == display.x11.state);
}

pub fn open(display: *Display) Error!void {
    assert(display.active == .none);

    if (display.try_wayland()) {
        display.active = .wayland;

        return;
    }

    if (display.try_x11()) {
        display.active = .x11;

        return;
    }

    return Error.Unavailable;
}

fn try_wayland(display: *Display) bool {
    var environ: sys.Environ = .{};

    environ.load();

    if (environ.get("WAYLAND_DISPLAY") == null) {
        return false;
    }

    display.wayland.open() catch {
        display.wayland.close();

        return false;
    };

    return true;
}

fn try_x11(display: *Display) bool {
    var environ: sys.Environ = .{};

    environ.load();

    if (environ.get("DISPLAY") == null) {
        return false;
    }

    display.x11.open() catch {
        display.x11.close();

        return false;
    };

    return true;
}

pub fn close(display: *Display) void {
    switch (display.active) {
        .none => {},
        .wayland => display.wayland.close(),
        .x11 => display.x11.close(),
    }

    display.active = .none;

    assert(display.active == .none);
}

pub fn selected(display: *const Display) Server {
    return display.active;
}

pub fn descriptor(display: *const Display) sys.Fd {
    const result = switch (display.active) {
        .none => -1,
        .wayland => display.wayland.descriptor(),
        .x11 => display.x11.descriptor(),
    };

    return result;
}

pub fn is_live(display: *const Display) bool {
    const result = switch (display.active) {
        .none => false,
        .wayland => display.wayland.is_live(),
        .x11 => display.x11.is_live(),
    };

    return result;
}

pub fn create(display: *Display, index: u16, slot: *const Slot) Error!void {
    assert(index < surface_module.count_max);

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.create(index, slot),
        .x11 => try display.x11.create(index, slot),
    }
}

pub fn destroy(display: *Display, index: u16) void {
    assert(index < surface_module.count_max);

    switch (display.active) {
        .none => {},
        .wayland => display.wayland.destroy(index),
        .x11 => display.x11.destroy(index),
    }
}

pub fn show(display: *Display, index: u16, slot: *const Slot) Error!void {
    assert(index < surface_module.count_max);

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.show(index, slot),
        .x11 => try display.x11.show(index, slot),
    }
}

pub fn hide(display: *Display, index: u16) void {
    assert(index < surface_module.count_max);

    switch (display.active) {
        .none => {},
        .wayland => display.wayland.hide(index),
        .x11 => display.x11.hide(index),
    }
}

pub fn is_mapped(display: *const Display, index: u16) bool {
    assert(index < surface_module.count_max);

    const result = switch (display.active) {
        .none => false,
        .wayland => display.wayland.is_mapped(index),
        .x11 => display.x11.is_mapped(index),
    };

    return result;
}

pub fn present(display: *Display, index: u16, slot: *const Slot, pixels: []const u32) Error!void {
    assert(index < surface_module.count_max);
    assert(pixels.len <= slot.pixel_count());

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.present(index, slot, pixels),
        .x11 => try display.x11.present(index, slot, pixels),
    }
}

pub fn shade_create(display: *Display, index: u16, slot: *const ShadeSlot) Error!void {
    assert(index < shade_module.count_max);
    assert(slot.used);

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.shade_create(index, slot),
        .x11 => try display.x11.shade_create(index, slot),
    }
}

pub fn shade_destroy(display: *Display, index: u16) void {
    assert(index < shade_module.count_max);

    switch (display.active) {
        .none => {},
        .wayland => display.wayland.shade_destroy(index),
        .x11 => display.x11.shade_destroy(index),
    }
}

pub fn shade_fill(display: *Display, index: u16, color: u32) Error!void {
    assert(index < shade_module.count_max);

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.shade_fill(index, color),
        .x11 => try display.x11.shade_fill(index, color),
    }
}

pub fn shade_cursor(display: *Display, index: u16, cursor: Cursor) Error!void {
    assert(index < shade_module.count_max);
    assert(@backingInt(cursor) <= @backingInt(Cursor.resize_northwest_southeast));

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.shade_cursor(index, cursor),
        .x11 => try display.x11.shade_cursor(index, cursor),
    }
}

pub fn shade_place(display: *Display, index: u16, rect: Rect) Error!void {
    assert(index < shade_module.count_max);
    assert(rect.width > 0);
    assert(rect.height > 0);

    switch (display.active) {
        .none => return Error.Unavailable,
        .wayland => try display.wayland.shade_place(index, rect),
        .x11 => try display.x11.shade_place(index, rect),
    }
}

pub fn pump(display: *Display) void {
    switch (display.active) {
        .none => {},
        .wayland => display.wayland.pump(),
        .x11 => display.x11.pump(),
    }
}

pub fn take_restack(display: *Display) bool {
    return switch (display.active) {
        .none => false,
        .wayland => display.wayland.take_restack(),
        .x11 => display.x11.take_restack(),
    };
}

fn assert_display(comptime Client: type) void {
    comptime {
        require_fn(Client, "open", fn (*Client) Error!void);
        require_fn(Client, "close", fn (*Client) void);
        require_fn(Client, "descriptor", fn (*const Client) sys.Fd);
        require_fn(Client, "is_live", fn (*const Client) bool);
        require_fn(Client, "create", fn (*Client, u16, *const Slot) Error!void);
        require_fn(Client, "destroy", fn (*Client, u16) void);
        require_fn(Client, "show", fn (*Client, u16, *const Slot) Error!void);
        require_fn(Client, "hide", fn (*Client, u16) void);
        require_fn(Client, "is_mapped", fn (*const Client, u16) bool);
        require_fn(Client, "present", fn (*Client, u16, *const Slot, []const u32) Error!void);
        require_fn(Client, "pump", fn (*Client) void);
        require_fn(Client, "take_restack", fn (*Client) bool);
        require_fn(Client, "shade_create", fn (*Client, u16, *const ShadeSlot) Error!void);
        require_fn(Client, "shade_destroy", fn (*Client, u16) void);
        require_fn(Client, "shade_fill", fn (*Client, u16, u32) Error!void);
        require_fn(Client, "shade_place", fn (*Client, u16, Rect) Error!void);
        require_fn(Client, "shade_cursor", fn (*Client, u16, Cursor) Error!void);
    }
}

fn require_fn(comptime scope: type, comptime name: []const u8, comptime Signature: type) void {
    assert(name.len > 0);
    assert(std.mem.findScalar(u8, name, '.') == null);

    if (!@hasDecl(scope, name)) {
        @compileError("kalymma display backend is missing declaration '" ++ name ++ "'");
    }

    const Actual = @TypeOf(@field(scope, name));

    if (Actual != Signature) {
        @compileError(
            "kalymma display backend " ++ name ++ " has type " ++ @typeName(Actual) ++
                ", expected " ++ @typeName(Signature),
        );
    }
}

const testing = std.testing;

test "a closed display reports no descriptor and refuses every operation" {
    const state = try testing.allocator.create(State);
    defer testing.allocator.destroy(state);

    state.* = .{};

    var display: Display = undefined;

    display.init(state);
    display.close();

    const slot = Slot{ .height = 8, .used = true, .width = 8 };

    try testing.expectEqual(Server.none, display.selected());
    try testing.expectEqual(@as(sys.Fd, -1), display.descriptor());
    try testing.expect(!display.is_live());
    try testing.expect(!display.is_mapped(0));
    try testing.expectError(Error.Unavailable, display.create(0, &slot));
    try testing.expectError(Error.Unavailable, display.show(0, &slot));
    try testing.expectError(Error.Unavailable, display.present(0, &slot, &.{}));

    const shade = ShadeSlot{
        .color = 0x80000000,
        .rect = .{ .height = 8, .width = 8 },
        .used = true,
    };

    try testing.expectError(Error.Unavailable, display.shade_create(0, &shade));
    try testing.expectError(Error.Unavailable, display.shade_fill(0, 0x80000000));
    try testing.expectError(Error.Unavailable, display.shade_place(0, shade.rect));
    try testing.expectError(Error.Unavailable, display.shade_cursor(0, .move));
}
