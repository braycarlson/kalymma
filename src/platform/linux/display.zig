const std = @import("std");

const contract = @import("../contract.zig");
const seam = @import("seam.zig");
const sys = @import("sys.zig");
const wayland = @import("wayland/client.zig");
const x11 = @import("x11/client.zig");

const assert = std.debug.assert;

const Slot = contract.Slot;

pub const Error = seam.Error;

pub const Display = enum(u8) {
    none = 0,
    wayland = 1,
    x11 = 2,
};

comptime {
    assert_display(wayland);
    assert_display(x11);
}

var active: Display = .none;

pub fn open() Error!void {
    assert(active == .none);

    if (try_wayland()) {
        active = .wayland;

        return;
    }

    if (try_x11()) {
        active = .x11;

        return;
    }

    return Error.Unavailable;
}

fn try_wayland() bool {
    if (sys.getenv("WAYLAND_DISPLAY") == null) {
        return false;
    }

    wayland.open() catch {
        wayland.close();

        return false;
    };

    return true;
}

fn try_x11() bool {
    if (sys.getenv("DISPLAY") == null) {
        return false;
    }

    x11.open() catch {
        x11.close();

        return false;
    };

    return true;
}

pub fn close() void {
    switch (active) {
        .none => {},
        .wayland => wayland.close(),
        .x11 => x11.close(),
    }

    active = .none;

    assert(active == .none);
}

pub fn selected() Display {
    return active;
}

pub fn descriptor() sys.Fd {
    const result = switch (active) {
        .none => -1,
        .wayland => wayland.descriptor(),
        .x11 => x11.descriptor(),
    };

    return result;
}

pub fn is_live() bool {
    const result = switch (active) {
        .none => false,
        .wayland => wayland.is_live(),
        .x11 => x11.is_live(),
    };

    return result;
}

pub fn create(index: u16, slot: *const Slot) Error!void {
    switch (active) {
        .none => return Error.Unavailable,
        .wayland => try wayland.create(index, slot),
        .x11 => try x11.create(index, slot),
    }
}

pub fn destroy(index: u16) void {
    switch (active) {
        .none => {},
        .wayland => wayland.destroy(index),
        .x11 => x11.destroy(index),
    }
}

pub fn show(index: u16, slot: *const Slot) Error!void {
    switch (active) {
        .none => return Error.Unavailable,
        .wayland => try wayland.show(index, slot),
        .x11 => try x11.show(index, slot),
    }
}

pub fn hide(index: u16) void {
    switch (active) {
        .none => {},
        .wayland => wayland.hide(index),
        .x11 => x11.hide(index),
    }
}

pub fn is_mapped(index: u16) bool {
    const result = switch (active) {
        .none => false,
        .wayland => wayland.is_mapped(index),
        .x11 => x11.is_mapped(index),
    };

    return result;
}

pub fn present(index: u16, slot: *const Slot, pixels: []const u32) Error!void {
    switch (active) {
        .none => return Error.Unavailable,
        .wayland => try wayland.present(index, slot, pixels),
        .x11 => try x11.present(index, slot, pixels),
    }
}

pub fn pump() void {
    switch (active) {
        .none => {},
        .wayland => wayland.pump(),
        .x11 => x11.pump(),
    }
}

fn assert_display(comptime backend: type) void {
    comptime {
        require_fn(backend, "open", fn () Error!void);
        require_fn(backend, "close", fn () void);
        require_fn(backend, "descriptor", fn () sys.Fd);
        require_fn(backend, "is_live", fn () bool);
        require_fn(backend, "create", fn (u16, *const Slot) Error!void);
        require_fn(backend, "destroy", fn (u16) void);
        require_fn(backend, "show", fn (u16, *const Slot) Error!void);
        require_fn(backend, "hide", fn (u16) void);
        require_fn(backend, "is_mapped", fn (u16) bool);
        require_fn(backend, "present", fn (u16, *const Slot, []const u32) Error!void);
        require_fn(backend, "pump", fn () void);
    }
}

fn require_fn(comptime scope: type, comptime name: []const u8, comptime Signature: type) void {
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

test "a closed seam reports no descriptor and refuses every operation" {
    close();

    const slot = Slot{ .height = 8, .used = true, .width = 8 };

    try testing.expectEqual(Display.none, selected());
    try testing.expectEqual(@as(sys.Fd, -1), descriptor());
    try testing.expect(!is_live());
    try testing.expect(!is_mapped(0));
    try testing.expectError(Error.Unavailable, create(0, &slot));
    try testing.expectError(Error.Unavailable, show(0, &slot));
    try testing.expectError(Error.Unavailable, present(0, &slot, &.{}));
}
