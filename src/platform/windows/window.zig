const std = @import("std");

const contract = @import("../contract.zig");
const geometry = @import("../geometry.zig");
const state = @import("state.zig");
const win32 = @import("win32.zig");

const assert = std.debug.assert;

const Anchor = contract.Anchor;
const Key = contract.Key;
const Point = contract.Point;
const Slot = contract.Slot;

pub const message_create: u32 = win32.WM_APP + 1;
pub const message_destroy: u32 = win32.WM_APP + 2;
pub const message_show: u32 = win32.WM_APP + 3;
pub const message_hide: u32 = win32.WM_APP + 4;
pub const message_present: u32 = win32.WM_APP + 5;
pub const message_stop: u32 = win32.WM_APP + 6;

pub const result_ok: win32.LRESULT = 0;
pub const result_failed: win32.LRESULT = 1;

pub const controller_class = std.unicode.utf8ToUtf16LeStringLiteral("kalymma_controller");
pub const surface_class = std.unicode.utf8ToUtf16LeStringLiteral("kalymma_surface");

comptime {
    assert(message_create > win32.WM_APP);
    assert(message_stop > message_present);
    assert(result_ok != result_failed);
}

pub fn instance() ?win32.HINSTANCE {
    return win32.GetModuleHandleW(null);
}

pub fn register_classes() bool {
    if (!register_one(controller_class, controller_proc)) {
        return false;
    }

    return register_one(surface_class, surface_proc);
}

pub fn unregister_classes() void {
    _ = win32.UnregisterClassW(surface_class, instance());
    _ = win32.UnregisterClassW(controller_class, instance());
}

fn register_one(name: [*:0]const u16, procedure: win32.WNDPROC) bool {
    const description = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = procedure,
        .hInstance = instance(),
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .lpszClassName = name,
    };

    if (win32.RegisterClassExW(&description) != 0) {
        return true;
    }

    return win32.GetLastError() == win32.ERROR_CLASS_ALREADY_EXISTS;
}

pub fn create_controller() ?win32.HWND {
    return win32.CreateWindowExW(
        0,
        controller_class,
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        instance(),
        null,
    );
}

fn controller_proc(
    window: win32.HWND,
    message: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (message) {
        message_create => return on_create(@intCast(wparam)),
        message_destroy => return on_destroy(@intCast(wparam)),
        message_show => return on_show(@intCast(wparam)),
        message_hide => return on_hide(@intCast(wparam)),
        message_present => return on_present(@intCast(wparam)),
        message_stop => {
            win32.PostQuitMessage(0);

            return result_ok;
        },
        else => {},
    }

    return win32.DefWindowProcW(window, message, wparam, lparam);
}

fn on_create(index: u16) win32.LRESULT {
    assert(index < state.surfaces_max);

    const slot = state.slot_at(index);
    const entry = state.window_at(index);

    const handle = win32.CreateWindowExW(
        win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_LAYERED,
        surface_class,
        null,
        win32.WS_POPUP,
        0,
        0,
        @intCast(slot.width),
        @intCast(slot.height),
        null,
        null,
        instance(),
        null,
    ) orelse {
        return result_failed;
    };

    entry.handle = handle;

    _ = win32.SetWindowLongPtrW(handle, win32.GWLP_USERDATA, @as(isize, index) + 1);

    if (!create_surface_bitmap(index, slot)) {
        destroy_window(index);

        return result_failed;
    }

    return result_ok;
}

fn create_surface_bitmap(index: u16, slot: *const Slot) bool {
    const entry = state.window_at(index);

    const screen = win32.GetDC(null) orelse return false;
    defer _ = win32.ReleaseDC(null, screen);

    const memory = win32.CreateCompatibleDC(screen) orelse return false;

    entry.memory = memory;

    var info = win32.BITMAPINFO{};

    info.bmiHeader = .{
        .biSize = @sizeOf(win32.BITMAPINFOHEADER),
        .biWidth = @intCast(slot.width),
        .biHeight = -@as(i32, @intCast(slot.height)),
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = win32.BI_RGB,
    };

    var bits: ?*anyopaque = null;

    const dib = win32.CreateDIBSection(
        memory,
        &info,
        win32.DIB_RGB_COLORS,
        &bits,
        null,
        0,
    ) orelse {
        return false;
    };

    entry.dib = dib;
    entry.bits = @ptrCast(@alignCast(bits));

    _ = win32.SelectObject(memory, @ptrCast(dib));

    return entry.bits != null;
}

fn on_destroy(index: u16) win32.LRESULT {
    destroy_window(index);

    return result_ok;
}

fn destroy_window(index: u16) void {
    assert(index < state.surfaces_max);

    const entry = state.window_at(index);

    if (entry.handle) |handle| {
        _ = win32.SetWindowLongPtrW(handle, win32.GWLP_USERDATA, 0);
        _ = win32.DestroyWindow(handle);
    }

    if (entry.memory) |memory| {
        _ = win32.DeleteDC(memory);
    }

    if (entry.dib) |dib| {
        _ = win32.DeleteObject(@ptrCast(dib));
    }

    entry.* = .{};

    assert(entry.handle == null);
}

fn on_show(index: u16) win32.LRESULT {
    assert(index < state.surfaces_max);

    const entry = state.window_at(index);
    const slot = state.slot_at(index);

    const handle = entry.handle orelse {
        return result_failed;
    };

    const origin = place(slot);

    _ = win32.SetWindowPos(
        handle,
        win32.HWND_TOPMOST,
        origin.x,
        origin.y,
        @intCast(slot.width),
        @intCast(slot.height),
        win32.SWP_SHOWWINDOW,
    );

    _ = win32.ShowWindow(handle, win32.SW_SHOW);
    _ = win32.SetForegroundWindow(handle);

    slot.visible = true;

    return present_locked(index);
}

fn on_hide(index: u16) win32.LRESULT {
    assert(index < state.surfaces_max);

    const entry = state.window_at(index);
    const slot = state.slot_at(index);

    slot.visible = false;

    const handle = entry.handle orelse {
        return result_failed;
    };

    _ = win32.ShowWindow(handle, win32.SW_HIDE);

    return result_ok;
}

fn on_present(index: u16) win32.LRESULT {
    return present_locked(index);
}

fn present_locked(index: u16) win32.LRESULT {
    assert(index < state.surfaces_max);

    const entry = state.window_at(index);
    const slot = state.slot_at(index);

    const handle = entry.handle orelse {
        return result_failed;
    };

    const bits = entry.bits orelse {
        return result_failed;
    };

    const memory = entry.memory orelse {
        return result_failed;
    };

    state.copy_frame(index, bits);

    const screen = win32.GetDC(null) orelse {
        return result_failed;
    };

    defer _ = win32.ReleaseDC(null, screen);

    var window_rect = win32.RECT{};

    _ = win32.GetWindowRect(handle, &window_rect);

    const destination = win32.POINT{ .x = window_rect.left, .y = window_rect.top };
    const source = win32.POINT{ .x = 0, .y = 0 };

    const size = win32.SIZE{
        .cx = @intCast(slot.width),
        .cy = @intCast(slot.height),
    };

    const blend = win32.BLENDFUNCTION{};

    const updated = win32.UpdateLayeredWindow(
        handle,
        screen,
        &destination,
        &size,
        memory,
        &source,
        0,
        &blend,
        win32.ULW_ALPHA,
    );

    if (updated == win32.FALSE) {
        return result_failed;
    }

    return result_ok;
}

pub fn place(slot: *const Slot) win32.POINT {
    var cursor = win32.POINT{};

    _ = win32.GetCursorPos(&cursor);

    var info = win32.MONITORINFO{ .cbSize = @sizeOf(win32.MONITORINFO) };

    const monitor = win32.MonitorFromPoint(cursor, win32.MONITOR_DEFAULTTONEAREST);

    if (monitor) |present| {
        _ = win32.GetMonitorInfoW(present, &info);
    }

    const work = info.rcWork;

    return anchor_point(
        work,
        @intCast(slot.width),
        @intCast(slot.height),
        @intCast(slot.margin),
        slot.anchor,
    );
}

pub fn anchor_point(
    work: win32.RECT,
    width: i32,
    height: i32,
    margin: i32,
    anchor: Anchor,
) win32.POINT {
    const area = geometry.Rect{
        .height = work.bottom - work.top,
        .width = work.right - work.left,
        .x = work.left,
        .y = work.top,
    };

    const origin = geometry.anchor_point(area, width, height, margin, anchor);

    return win32.POINT{ .x = origin.x, .y = origin.y };
}

pub fn to_key(virtual_key: u32) Key {
    const result: Key = switch (virtual_key) {
        win32.VK_ESCAPE => .escape,
        win32.VK_RETURN => .enter,
        win32.VK_SPACE => .space,
        win32.VK_LEFT => .left,
        win32.VK_RIGHT => .right,
        win32.VK_UP => .up,
        win32.VK_DOWN => .down,
        else => .other,
    };

    assert(result.is_valid());

    return result;
}

pub fn to_point(lparam: win32.LPARAM) Point {
    const x: i16 = @truncate(lparam & 0xFFFF);
    const y: i16 = @truncate((lparam >> 16) & 0xFFFF);

    return .{ .x = x, .y = y };
}

fn index_of(window: win32.HWND) ?u16 {
    const stored = win32.GetWindowLongPtrW(window, win32.GWLP_USERDATA);

    if (stored <= 0) {
        return null;
    }

    const result: u16 = @intCast(stored - 1);

    if (result >= state.surfaces_max) {
        return null;
    }

    return result;
}

fn surface_proc(
    window: win32.HWND,
    message: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    const index = index_of(window) orelse {
        return win32.DefWindowProcW(window, message, wparam, lparam);
    };

    switch (message) {
        win32.WM_MOUSEMOVE => {
            track_leave(index, window);
            state.publish(index, .{ .pointer_move = to_point(lparam) });

            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            _ = win32.SetCapture(window);
            state.publish(index, .{ .pointer_down = to_point(lparam) });

            return 0;
        },
        win32.WM_LBUTTONUP => {
            _ = win32.ReleaseCapture();
            state.publish(index, .{ .pointer_up = to_point(lparam) });

            return 0;
        },
        win32.WM_MOUSELEAVE => {
            state.window_at(index).tracking = false;
            state.publish(index, .{ .pointer_leave = {} });

            return 0;
        },
        win32.WM_KEYDOWN => {
            state.publish(index, .{ .key_down = to_key(@truncate(wparam)) });

            return 0;
        },
        win32.WM_KILLFOCUS => {
            state.publish(index, .{ .focus_lost = {} });

            return 0;
        },
        else => {},
    }

    return win32.DefWindowProcW(window, message, wparam, lparam);
}

fn track_leave(index: u16, window: win32.HWND) void {
    const entry = state.window_at(index);

    if (entry.tracking) {
        return;
    }

    var request = win32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = window,
        .dwHoverTime = 0,
    };

    if (win32.TrackMouseEvent(&request) != win32.FALSE) {
        entry.tracking = true;
    }
}

const testing = std.testing;

test "the message codes stay above the application range and stay distinct" {
    try testing.expect(message_create > win32.WM_APP);
    try testing.expect(message_destroy != message_create);
    try testing.expect(message_stop != message_present);
}

test "a win32 work rectangle anchors from its own origin" {
    const work = win32.RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };

    const bottom = anchor_point(work, 380, 220, 12, .bottom_right);

    try testing.expectEqual(@as(i32, 1528), bottom.x);
    try testing.expectEqual(@as(i32, 808), bottom.y);

    const offset = win32.RECT{ .left = 100, .top = 50, .right = 300, .bottom = 150 };
    const placed = anchor_point(offset, 380, 220, 12, .bottom_right);

    try testing.expectEqual(@as(i32, 100), placed.x);
    try testing.expectEqual(@as(i32, 50), placed.y);
}

test "a virtual key outside the overlay vocabulary maps to other" {
    try testing.expectEqual(Key.escape, to_key(win32.VK_ESCAPE));
    try testing.expectEqual(Key.enter, to_key(win32.VK_RETURN));
    try testing.expectEqual(Key.space, to_key(win32.VK_SPACE));
    try testing.expectEqual(Key.left, to_key(win32.VK_LEFT));
    try testing.expectEqual(Key.right, to_key(win32.VK_RIGHT));
    try testing.expectEqual(Key.up, to_key(win32.VK_UP));
    try testing.expectEqual(Key.down, to_key(win32.VK_DOWN));
    try testing.expectEqual(Key.other, to_key(0x41));
}

test "a packed coordinate unpacks as a signed pair" {
    const inside = to_point(@as(win32.LPARAM, 34 << 16) | 12);

    try testing.expectEqual(@as(i32, 12), inside.x);
    try testing.expectEqual(@as(i32, 34), inside.y);

    const negative = to_point(@as(win32.LPARAM, 0xFFF6 << 16) | 0xFFFB);

    try testing.expectEqual(@as(i32, -5), negative.x);
    try testing.expectEqual(@as(i32, -10), negative.y);
}
