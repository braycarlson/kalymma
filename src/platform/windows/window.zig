const std = @import("std");

const event_module = @import("../../event.zig");
const geometry = @import("../geometry.zig");
const interface = @import("../interface.zig");
const monitor_module = @import("../../monitor.zig");
const shade_module = @import("../../shade.zig");
const State = @import("state.zig");
const surface_module = @import("../../surface.zig");
const win32 = @import("win32.zig");

const assert = std.debug.assert;

const Cursor = shade_module.Cursor;
const Key = event_module.Key;
const Monitor = monitor_module.Monitor;
const Point = event_module.Point;
const Rect = geometry.Rect;
const ShadeWindow = State.ShadeWindow;
const Slot = interface.Slot;

pub const message_create: u32 = win32.WM_APP + 1;
pub const message_destroy: u32 = win32.WM_APP + 2;
pub const message_show: u32 = win32.WM_APP + 3;
pub const message_hide: u32 = win32.WM_APP + 4;
pub const message_present: u32 = win32.WM_APP + 5;
pub const message_stop: u32 = win32.WM_APP + 6;
pub const message_shade_create: u32 = win32.WM_APP + 7;
pub const message_shade_destroy: u32 = win32.WM_APP + 8;
pub const message_shade_fill: u32 = win32.WM_APP + 9;
pub const message_shade_place: u32 = win32.WM_APP + 10;
pub const message_tint_apply: u32 = win32.WM_APP + 11;
pub const message_tint_clear: u32 = win32.WM_APP + 12;
pub const message_tint_probe: u32 = win32.WM_APP + 13;
pub const message_shade_cursor: u32 = win32.WM_APP + 14;
pub const result_ok: win32.LRESULT = 0;
pub const result_failed: win32.LRESULT = 1;
pub const controller_class = std.unicode.utf8ToUtf16LeStringLiteral("kalymma_controller");
pub const shade_class = std.unicode.utf8ToUtf16LeStringLiteral("kalymma_shade");
pub const surface_class = std.unicode.utf8ToUtf16LeStringLiteral("kalymma_surface");
pub const device_fallback = "display";
pub const device_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\");
pub const device_units_max: u32 = @typeInfo(@FieldType(win32.MONITORINFOEXW, "szDevice")).array.len;
pub const device_name_bytes_max: u32 = device_units_max * 3;
pub const restack_interval_ms: u32 = 250;
pub const restack_timer: usize = 1;
const restack_flags: u32 = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE;
const shade_style: u32 = shade_style_interactive | win32.WS_EX_TRANSPARENT | win32.WS_EX_NOACTIVATE;

const shade_style_interactive: u32 =
    win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_LAYERED;

comptime {
    assert(message_create > win32.WM_APP);
    assert(message_stop > message_present);
    assert(message_shade_create > message_stop);
    assert(message_shade_place > message_shade_fill);
    assert(message_tint_apply > message_shade_place);
    assert(message_tint_probe > message_tint_clear);
    assert(message_shade_cursor > message_tint_probe);
    assert(result_ok != result_failed);
    assert(device_prefix.len == 4);
    assert(shade_style & win32.WS_EX_TRANSPARENT != 0);
    assert(shade_style_interactive & win32.WS_EX_TRANSPARENT == 0);
}

pub fn instance() ?win32.HINSTANCE {
    return win32.GetModuleHandleW(null);
}

pub fn is_station_visible() bool {
    const station = win32.GetProcessWindowStation() orelse return false;

    var flags = win32.USEROBJECTFLAGS{};

    const read = win32.GetUserObjectInformationW(
        @ptrCast(station),
        win32.UOI_FLAGS,
        &flags,
        @sizeOf(win32.USEROBJECTFLAGS),
        null,
    );

    if (read == win32.FALSE) {
        return false;
    }

    return flags.dwFlags & win32.WSF_VISIBLE != 0;
}

pub fn register_classes() bool {
    if (!register_one(controller_class, controller_proc, win32.IDC_ARROW)) {
        return false;
    }

    if (!register_one(shade_class, shade_proc, win32.IDC_CROSS)) {
        return false;
    }

    return register_one(surface_class, surface_proc, win32.IDC_ARROW);
}

pub fn unregister_classes() void {
    _ = win32.UnregisterClassW(surface_class, instance());
    _ = win32.UnregisterClassW(shade_class, instance());
    _ = win32.UnregisterClassW(controller_class, instance());
}

fn register_one(
    name: [*:0]const u16,
    procedure: win32.WNDPROC,
    cursor: [*:0]align(1) const u16,
) bool {
    assert(name[0] != 0);

    const description = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = procedure,
        .hInstance = instance(),
        .hCursor = win32.LoadCursorW(null, cursor),
        .lpszClassName = name,
    };

    if (win32.RegisterClassExW(&description) != 0) {
        return true;
    }

    return win32.GetLastError() == win32.ERROR_CLASS_ALREADY_EXISTS;
}

pub fn create_controller(state: *State) ?win32.HWND {
    return win32.CreateWindowExW(
        win32.WS_EX_TOOLWINDOW,
        controller_class,
        null,
        win32.WS_POPUP,
        0,
        0,
        0,
        0,
        null,
        null,
        instance(),
        state,
    );
}

pub fn release_windows(state: *State) void {
    for (0..shade_module.count_max) |position| {
        destroy_shade_window(state, @intCast(position));
    }

    for (0..surface_module.count_max) |position| {
        destroy_window(state, @intCast(position));
    }

    assert(state.shade_window_at(0).handle == null);
    assert(state.window_at(0).handle == null);
}

fn controller_proc(
    window: win32.HWND,
    message: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (message == win32.WM_NCCREATE) attach(window, lparam);

    const state = state_of(window) orelse {
        return win32.DefWindowProcW(window, message, wparam, lparam);
    };

    switch (message) {
        message_create => return on_create(state, @intCast(wparam)),
        message_destroy => return on_destroy(state, @intCast(wparam)),
        message_show => return on_show(state, @intCast(wparam)),
        message_hide => return on_hide(state, @intCast(wparam)),
        message_present => return on_present(state, @intCast(wparam)),
        message_shade_create => return on_shade_create(state, window, @intCast(wparam)),
        message_shade_destroy => return on_shade_destroy(state, @intCast(wparam)),
        message_shade_fill => return on_shade_fill(state, @intCast(wparam)),
        message_shade_place => return on_shade_place(state, @intCast(wparam)),
        message_shade_cursor => return on_shade_cursor(state, @intCast(wparam)),
        message_tint_apply => return on_tint_apply(state, @intCast(wparam)),
        message_tint_clear => return on_tint_clear(state),
        message_tint_probe => return on_tint_probe(state),
        message_stop => {
            win32.PostQuitMessage(0);

            return result_ok;
        },
        win32.WM_DISPLAYCHANGE => refresh_monitors(state),
        win32.WM_TIMER => {
            if (wparam == restack_timer) {
                restack(state, window);

                return 0;
            }
        },
        else => {},
    }

    return win32.DefWindowProcW(window, message, wparam, lparam);
}

pub fn refresh_monitors(state: *State) void {
    var list = Monitor.List.init();

    _ = win32.EnumDisplayMonitors(null, null, collect_monitor, @bitCast(@intFromPtr(&list)));

    assert(list.count <= monitor_module.count_max);

    state.set_monitors(&list);
}

fn collect_monitor(
    monitor: win32.HMONITOR,
    context: ?win32.HDC,
    clip: ?*win32.RECT,
    data: win32.LPARAM,
) callconv(.winapi) win32.BOOL {
    assert(context == null);
    assert(clip != null);

    const list: *Monitor.List = @ptrFromInt(@as(usize, @bitCast(data)));

    if (list.is_full()) {
        return win32.FALSE;
    }

    var info = win32.MONITORINFOEXW{ .cbSize = @sizeOf(win32.MONITORINFOEXW) };

    if (win32.GetMonitorInfoW(monitor, @ptrCast(&info)) == win32.FALSE) {
        return win32.TRUE;
    }

    const rect = area_of(info.rcMonitor);

    if (rect.is_empty()) {
        return win32.TRUE;
    }

    var buffer: [device_name_bytes_max]u8 = @splat(0);
    var entry = Monitor.init(device_name(&info.szDevice, &buffer), rect);
    entry.primary = (info.dwFlags & win32.MONITORINFOF_PRIMARY) != 0;

    list.append(entry);

    return win32.TRUE;
}

pub fn device_name(device: []const u16, buffer: []u8) []const u8 {
    assert(device.len <= device_units_max);
    assert(buffer.len >= device.len * 3);

    const length = std.mem.findScalar(u16, device, 0) orelse device.len;
    const full = device[0..length];
    const prefixed = std.mem.startsWith(u16, full, device_prefix);
    const name = if (prefixed) full[device_prefix.len..] else full;
    const written = std.unicode.utf16LeToUtf8(buffer, name) catch return device_fallback;

    if (written == 0) {
        return device_fallback;
    }

    assert(std.unicode.utf8ValidateSlice(buffer[0..written]));

    return buffer[0..written];
}

fn on_shade_create(state: *State, controller: win32.HWND, index: u16) win32.LRESULT {
    assert(index < shade_module.count_max);
    assert(state.shade_window_at(index).handle == null);

    const slot = state.shade_at(index);

    assert(slot.used);
    assert(!slot.rect.is_empty());

    const frame = frame_of(slot.rect);

    const handle = win32.CreateWindowExW(
        if (slot.interactive) shade_style_interactive else shade_style,
        shade_class,
        null,
        win32.WS_POPUP,
        frame.x,
        frame.y,
        frame.width,
        frame.height,
        null,
        null,
        instance(),
        state,
    ) orelse {
        return result_failed;
    };

    state.attach_shade_window(index, handle);
    state.shade_window_at(index).cursor = slot.cursor;
    state.shade_window_at(index).frame = frame;

    if (!clip_shade(handle, frame, slot.rect)) {
        destroy_shade_window(state, index);

        return result_failed;
    }

    if (!tint_shade(state, index, slot.color, slot.interactive)) {
        destroy_shade_window(state, index);

        return result_failed;
    }

    reveal_shade(handle, slot.interactive);
    raise_surfaces(state);

    _ = win32.SetTimer(controller, restack_timer, restack_interval_ms, null);

    return result_ok;
}

fn reveal_shade(handle: win32.HWND, interactive: bool) void {
    const flags = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_SHOWWINDOW;
    const quiet = flags | win32.SWP_NOACTIVATE;

    if (interactive) {
        _ = win32.SetWindowPos(handle, win32.HWND_TOPMOST, 0, 0, 0, 0, flags);
        _ = win32.SetForegroundWindow(handle);
    } else {
        _ = win32.SetWindowPos(handle, win32.HWND_TOPMOST, 0, 0, 0, 0, quiet);
    }
}

fn tint_shade(state: *State, index: u16, color: u32, interactive: bool) bool {
    assert(index < shade_module.count_max);

    const entry = state.shade_window_at(index);
    const handle = entry.handle orelse return false;
    const brush = win32.CreateSolidBrush(to_colorref(color)) orelse return false;
    const alpha = shade_alpha(color, interactive);

    if (win32.SetLayeredWindowAttributes(handle, 0, alpha, win32.LWA_ALPHA) == win32.FALSE) {
        _ = win32.DeleteObject(@ptrCast(brush));

        return false;
    }

    if (entry.brush) |previous| {
        _ = win32.DeleteObject(@ptrCast(previous));
    }

    entry.brush = brush;

    _ = win32.InvalidateRect(handle, null, win32.TRUE);

    return true;
}

pub fn shade_alpha(color: u32, interactive: bool) u8 {
    const alpha: u8 = @truncate(color >> 24);

    if (interactive) {
        return @max(alpha, 1);
    }

    return alpha;
}

pub fn to_colorref(color: u32) u32 {
    const red = (color >> 16) & 0xFF;
    const green = (color >> 8) & 0xFF;
    const blue = color & 0xFF;
    const result = red | (green << 8) | (blue << 16);

    assert(result <= 0xFFFFFF);

    return result;
}

fn on_shade_destroy(state: *State, index: u16) win32.LRESULT {
    assert(index < shade_module.count_max);

    destroy_shade_window(state, index);

    return result_ok;
}

fn destroy_shade_window(state: *State, index: u16) void {
    assert(index < shade_module.count_max);

    const entry = state.shade_window_at(index);

    if (entry.handle) |handle| {
        _ = win32.SetWindowLongPtrW(handle, win32.GWLP_USERDATA, 0);
        _ = win32.DestroyWindow(handle);
    }

    if (entry.brush) |brush| {
        _ = win32.DeleteObject(@ptrCast(brush));
    }

    entry.* = .{};

    assert(entry.handle == null);
}

fn on_shade_fill(state: *State, index: u16) win32.LRESULT {
    assert(index < shade_module.count_max);

    const slot = state.shade_at(index);

    assert(slot.used);

    if (!tint_shade(state, index, slot.color, slot.interactive)) {
        return result_failed;
    }

    return result_ok;
}

fn on_shade_place(state: *State, index: u16) win32.LRESULT {
    assert(index < shade_module.count_max);

    const slot = state.shade_at(index);

    assert(slot.used);
    assert(!slot.rect.is_empty());

    const entry = state.shade_window_at(index);
    const handle = entry.handle orelse return result_failed;
    const frame = frame_of(slot.rect);

    if (!std.meta.eql(frame, entry.frame)) {
        const placed = win32.SetWindowPos(
            handle,
            null,
            frame.x,
            frame.y,
            frame.width,
            frame.height,
            win32.SWP_NOACTIVATE | win32.SWP_NOZORDER,
        );

        if (placed == win32.FALSE) {
            return result_failed;
        }

        entry.frame = frame;
    }

    if (!clip_shade(handle, frame, slot.rect)) {
        return result_failed;
    }

    assert(std.meta.eql(entry.frame, frame));

    return result_ok;
}

fn frame_of(rect: Rect) Rect {
    assert(!rect.is_empty());
    assert(rect.width <= std.math.maxInt(i32) - rect.x);

    const bounds = win32.RECT{
        .bottom = rect.y + rect.height,
        .left = rect.x,
        .right = rect.x + rect.width,
        .top = rect.y,
    };

    const monitor = win32.MonitorFromRect(&bounds, win32.MONITOR_DEFAULTTONULL) orelse return rect;
    var info = win32.MONITORINFO{ .cbSize = @sizeOf(win32.MONITORINFO) };

    if (win32.GetMonitorInfoW(monitor, &info) == win32.FALSE) return rect;

    const area = Rect{
        .height = info.rcMonitor.bottom - info.rcMonitor.top,
        .width = info.rcMonitor.right - info.rcMonitor.left,
        .x = info.rcMonitor.left,
        .y = info.rcMonitor.top,
    };

    if (!area.encloses(rect)) return rect;
    return area;
}

fn clip_shade(handle: win32.HWND, frame: Rect, rect: Rect) bool {
    assert(!rect.is_empty());
    assert(frame.encloses(rect));

    if (std.meta.eql(frame, rect)) {
        return win32.SetWindowRgn(handle, null, win32.TRUE) != 0;
    }

    const left = rect.x - frame.x;
    const top = rect.y - frame.y;

    const region = win32.CreateRectRgn(left, top, left + rect.width, top + rect.height) orelse {
        return false;
    };

    if (win32.SetWindowRgn(handle, region, win32.TRUE) == 0) {
        _ = win32.DeleteObject(@ptrCast(region));

        return false;
    }

    return true;
}

fn on_shade_cursor(state: *State, index: u16) win32.LRESULT {
    assert(index < shade_module.count_max);

    const slot = state.shade_at(index);

    assert(slot.used);

    const entry = state.shade_window_at(index);
    const handle = entry.handle orelse return result_failed;

    entry.cursor = slot.cursor;

    if (is_under_pointer(handle)) {
        _ = win32.SetCursor(win32.LoadCursorW(null, resource_of(entry.cursor)));
    }

    assert(entry.cursor == slot.cursor);

    return result_ok;
}

fn is_under_pointer(handle: win32.HWND) bool {
    if (win32.GetCapture() == handle) return true;

    var point = win32.POINT{};

    if (win32.GetCursorPos(&point) == win32.FALSE) return false;
    return win32.WindowFromPoint(point) == handle;
}

pub fn resource_of(cursor: Cursor) [*:0]align(1) const u16 {
    const result = switch (cursor) {
        .arrow => win32.IDC_ARROW,
        .crosshair => win32.IDC_CROSS,
        .move => win32.IDC_SIZEALL,
        .resize_east_west => win32.IDC_SIZEWE,
        .resize_north_south => win32.IDC_SIZENS,
        .resize_northeast_southwest => win32.IDC_SIZENESW,
        .resize_northwest_southeast => win32.IDC_SIZENWSE,
    };

    assert(@intFromPtr(result) >= @intFromPtr(win32.IDC_ARROW));

    return result;
}

fn on_tint_apply(state: *State, color: u32) win32.LRESULT {
    if (!state.get_magnifier().apply(color)) {
        return result_failed;
    }

    return result_ok;
}

fn on_tint_clear(state: *State) win32.LRESULT {
    state.get_magnifier().clear();

    return result_ok;
}

fn on_tint_probe(state: *State) win32.LRESULT {
    if (!state.get_magnifier().is_available()) {
        return result_failed;
    }

    return result_ok;
}

fn restack(state: *State, controller: win32.HWND) void {
    var stack: [shade_module.count_max]ShadeWindow = @splat(.{});
    var count: u32 = 0;

    for (0..shade_module.count_max) |position| {
        const entry = state.shade_window_at(@intCast(position));

        if (entry.handle != null) {
            stack[count] = entry.*;
            count += 1;
        }
    }

    if (count == 0) {
        _ = win32.KillTimer(controller, restack_timer);

        return;
    }

    std.sort.insertion(ShadeWindow, stack[0..count], {}, is_older);

    for (stack[0..count]) |entry| {
        if (entry.handle) |handle| {
            _ = win32.SetWindowPos(handle, win32.HWND_TOPMOST, 0, 0, 0, 0, restack_flags);
        }
    }

    raise_surfaces(state);
}

fn raise_surfaces(state: *State) void {
    for (0..surface_module.count_max) |position| {
        const index: u16 = @intCast(position);
        const handle = state.window_at(index).handle orelse continue;

        if (!state.slot_at(index).visible) continue;

        _ = win32.SetWindowPos(handle, win32.HWND_TOPMOST, 0, 0, 0, 0, restack_flags);
    }
}

pub fn is_older(context: void, left: ShadeWindow, right: ShadeWindow) bool {
    _ = context;

    assert(left.sequence != right.sequence);

    return left.sequence < right.sequence;
}

fn on_create(state: *State, index: u16) win32.LRESULT {
    assert(index < surface_module.count_max);

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
        state,
    ) orelse {
        return result_failed;
    };

    entry.handle = handle;

    if (!create_surface_bitmap(state, index, slot)) {
        destroy_window(state, index);

        return result_failed;
    }

    return result_ok;
}

fn create_surface_bitmap(state: *State, index: u16, slot: *const Slot) bool {
    assert(index < surface_module.count_max);
    assert(state.window_at(index).memory == null);

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

fn on_destroy(state: *State, index: u16) win32.LRESULT {
    assert(index < surface_module.count_max);

    destroy_window(state, index);

    return result_ok;
}

fn destroy_window(state: *State, index: u16) void {
    assert(index < surface_module.count_max);

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

fn on_show(state: *State, index: u16) win32.LRESULT {
    assert(index < surface_module.count_max);

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

    return present_locked(state, index);
}

fn on_hide(state: *State, index: u16) win32.LRESULT {
    assert(index < surface_module.count_max);

    const entry = state.window_at(index);
    const slot = state.slot_at(index);

    slot.visible = false;

    const handle = entry.handle orelse {
        return result_failed;
    };

    _ = win32.ShowWindow(handle, win32.SW_HIDE);

    return result_ok;
}

fn on_present(state: *State, index: u16) win32.LRESULT {
    assert(index < surface_module.count_max);

    return present_locked(state, index);
}

fn present_locked(state: *State, index: u16) win32.LRESULT {
    assert(index < surface_module.count_max);

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

    const origin = geometry.anchor_point(area_of(info.rcWork), geometry.placement_of(slot));
    return win32.POINT{ .x = origin.x, .y = origin.y };
}

pub fn area_of(work: win32.RECT) geometry.Rect {
    const result = geometry.Rect{
        .height = @max(work.bottom -| work.top, 0),
        .width = @max(work.right -| work.left, 0),
        .x = work.left,
        .y = work.top,
    };

    assert(result.height >= 0);
    assert(result.width >= 0);

    return result;
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

fn attach(window: win32.HWND, lparam: win32.LPARAM) void {
    assert(lparam != 0);

    const creation: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const owner = creation.lpCreateParams orelse return;
    const stored: isize = @bitCast(@intFromPtr(owner));

    _ = win32.SetWindowLongPtrW(window, win32.GWLP_USERDATA, stored);

    assert(state_of(window) != null);
}

fn state_of(window: win32.HWND) ?*State {
    const stored = win32.GetWindowLongPtrW(window, win32.GWLP_USERDATA);

    if (stored == 0) {
        return null;
    }

    const result: *State = @ptrFromInt(@as(usize, @bitCast(stored)));

    assert(@intFromPtr(result) % @alignOf(State) == 0);

    return result;
}

fn surface_index_of(state: *const State, window: win32.HWND) ?u16 {
    for (state.windows, 0..) |entry, position| {
        if (entry.handle != window) continue;

        const result: u16 = @intCast(position);

        assert(result < surface_module.count_max);

        return result;
    }

    return null;
}

fn shade_index_of(state: *const State, window: win32.HWND) ?u16 {
    for (state.shade_windows, 0..) |entry, position| {
        if (entry.handle != window) continue;

        const result: u16 = @intCast(position);

        assert(result < shade_module.count_max);

        return result;
    }

    return null;
}

fn shade_proc(
    window: win32.HWND,
    message: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (message == win32.WM_NCCREATE) attach(window, lparam);

    const state = state_of(window) orelse {
        return win32.DefWindowProcW(window, message, wparam, lparam);
    };

    const index = shade_index_of(state, window) orelse {
        return win32.DefWindowProcW(window, message, wparam, lparam);
    };

    assert(state.shade_window_at(index).handle == window);

    switch (message) {
        win32.WM_ERASEBKGND => return erase_shade(state, index, window, wparam),
        win32.WM_SETCURSOR => return point_shade(state, index, window, wparam, lparam),
        win32.WM_MOUSEMOVE => state.publish_shade(index, .{ .pointer_move = to_point(lparam) }),
        win32.WM_LBUTTONDOWN => {
            _ = win32.SetCapture(window);

            state.publish_shade(index, .{ .pointer_down = to_point(lparam) });
        },
        win32.WM_LBUTTONUP => {
            _ = win32.ReleaseCapture();

            state.publish_shade(index, .{ .pointer_up = to_point(lparam) });
        },
        win32.WM_KEYDOWN => state.publish_shade(index, .{ .key_down = to_key(@truncate(wparam)) }),
        win32.WM_KILLFOCUS => state.publish_shade(index, .{ .focus_lost = {} }),
        else => return win32.DefWindowProcW(window, message, wparam, lparam),
    }

    return 0;
}

fn point_shade(
    state: *State,
    index: u16,
    window: win32.HWND,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    assert(index < shade_module.count_max);
    assert(state.shade_window_at(index).handle == window);
    assert(wparam != 0);
    assert(@as(usize, @bitCast(lparam)) >> 32 == 0);

    const hit: u16 = @truncate(@as(usize, @bitCast(lparam)));

    if (hit != win32.HTCLIENT) {
        return win32.DefWindowProcW(window, win32.WM_SETCURSOR, wparam, lparam);
    }

    const cursor = state.shade_window_at(index).cursor;

    _ = win32.SetCursor(win32.LoadCursorW(null, resource_of(cursor)));

    return 1;
}

fn erase_shade(state: *State, index: u16, window: win32.HWND, wparam: win32.WPARAM) win32.LRESULT {
    assert(index < shade_module.count_max);
    assert(state.shade_window_at(index).handle == window);

    const brush = state.shade_window_at(index).brush orelse return 0;
    const context: ?win32.HDC = @ptrFromInt(wparam);
    const target = context orelse return 0;

    var area = win32.RECT{};

    _ = win32.GetClientRect(window, &area);
    _ = win32.FillRect(target, &area, brush);

    return 1;
}

fn surface_proc(
    window: win32.HWND,
    message: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (message == win32.WM_NCCREATE) attach(window, lparam);

    const state = state_of(window) orelse {
        return win32.DefWindowProcW(window, message, wparam, lparam);
    };

    const index = surface_index_of(state, window) orelse {
        return win32.DefWindowProcW(window, message, wparam, lparam);
    };

    assert(state.window_at(index).handle == window);

    switch (message) {
        win32.WM_MOUSEMOVE => {
            track_leave(state, index, window);
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

fn track_leave(state: *State, index: u16, window: win32.HWND) void {
    assert(index < surface_module.count_max);
    assert(state.window_at(index).handle == window);

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

test "each cursor loads a distinct system cursor" {
    const cursors = std.enums.values(Cursor);

    for (cursors, 0..) |cursor, position| {
        for (cursors[position + 1 ..]) |other| {
            try testing.expect(resource_of(cursor) != resource_of(other));
        }
    }

    try testing.expectEqual(win32.IDC_CROSS, resource_of(.crosshair));
    try testing.expectEqual(win32.IDC_SIZEWE, resource_of(.resize_east_west));
}

test "the message codes stay above the application range and stay distinct" {
    try testing.expect(message_create > win32.WM_APP);
    try testing.expect(message_destroy != message_create);
    try testing.expect(message_stop != message_present);

    const codes = [_]u32{
        message_create,
        message_destroy,
        message_show,
        message_hide,
        message_present,
        message_stop,
        message_shade_create,
        message_shade_destroy,
        message_shade_fill,
        message_shade_place,
        message_tint_apply,
        message_tint_clear,
        message_tint_probe,
        message_shade_cursor,
    };

    for (codes, 0..) |code, position| {
        for (codes[position + 1 ..]) |other| {
            try testing.expect(code != other);
        }
    }
}

test "an ARGB color maps to the COLORREF the RGB macro builds" {
    try testing.expectEqual(@as(u32, 0x000000FF), to_colorref(0xFFFF0000));
    try testing.expectEqual(@as(u32, 0x0000FF00), to_colorref(0xFF00FF00));
    try testing.expectEqual(@as(u32, 0x00FF0000), to_colorref(0xFF0000FF));
    try testing.expectEqual(@as(u32, 0x00563412), to_colorref(0x80123456));
    try testing.expectEqual(@as(u32, 0), to_colorref(0x99000000));
}

test "an interactive shade never turns fully transparent to the pointer" {
    try testing.expectEqual(@as(u8, 0), shade_alpha(0x00FFFFFF, false));
    try testing.expectEqual(@as(u8, 1), shade_alpha(0x00FFFFFF, true));
    try testing.expectEqual(@as(u8, 0x99), shade_alpha(0x99000000, false));
    try testing.expectEqual(@as(u8, 0x99), shade_alpha(0x99000000, true));
    try testing.expectEqual(@as(u8, 0xFF), shade_alpha(0xFF000000, true));
}

test "a device path loses its prefix and keeps the rest of its name" {
    var buffer: [device_name_bytes_max]u8 = @splat(0);
    var device: [device_units_max]u16 = @splat(0);

    const path = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\DISPLAY1");

    @memcpy(device[0..path.len], path);

    try testing.expectEqualStrings("DISPLAY1", device_name(&device, &buffer));

    const bare = std.unicode.utf8ToUtf16LeStringLiteral("Monitor");

    try testing.expectEqualStrings("Monitor", device_name(bare, &buffer));
    try testing.expectEqualStrings(device_fallback, device_name(device_prefix, &buffer));

    const unpaired = [_]u16{ 0x0041, 0xD800, 0x0042 };

    try testing.expectEqualStrings(device_fallback, device_name(&unpaired, &buffer));

    const full: [device_units_max]u16 = @splat('W');
    const name = device_name(&full, &buffer);

    try testing.expectEqual(@as(usize, device_units_max), name.len);
}

test "the restack order puts the oldest shade first and the newest on top" {
    var stack = [_]ShadeWindow{
        .{ .sequence = 7 },
        .{ .sequence = 2 },
        .{ .sequence = 9 },
        .{ .sequence = 4 },
    };

    std.sort.insertion(ShadeWindow, &stack, {}, is_older);

    try testing.expectEqual(@as(u32, 2), stack[0].sequence);
    try testing.expectEqual(@as(u32, 4), stack[1].sequence);
    try testing.expectEqual(@as(u32, 7), stack[2].sequence);
    try testing.expectEqual(@as(u32, 9), stack[3].sequence);
}

test "a win32 work rectangle anchors from its own origin" {
    const placement = geometry.Placement{
        .anchor = .bottom_right,
        .height = 220,
        .margin = 12,
        .width = 380,
    };

    const work = win32.RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const bottom = geometry.anchor_point(area_of(work), placement);

    try testing.expectEqual(@as(i32, 1528), bottom.x);
    try testing.expectEqual(@as(i32, 808), bottom.y);

    const offset = win32.RECT{ .left = 100, .top = 50, .right = 300, .bottom = 150 };
    const placed = geometry.anchor_point(area_of(offset), placement);

    try testing.expectEqual(@as(i32, 100), placed.x);
    try testing.expectEqual(@as(i32, 50), placed.y);
}

test "an inverted or extreme work rectangle yields an empty area at its origin" {
    const inverted = area_of(.{ .left = 300, .top = 200, .right = 100, .bottom = 50 });

    try testing.expectEqual(@as(i32, 0), inverted.width);
    try testing.expectEqual(@as(i32, 0), inverted.height);

    const extreme = area_of(.{
        .left = std.math.minInt(i32),
        .top = std.math.minInt(i32),
        .right = std.math.maxInt(i32),
        .bottom = std.math.maxInt(i32),
    });

    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), extreme.width);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), extreme.height);

    const placement = geometry.Placement{
        .anchor = .bottom_right,
        .height = 220,
        .margin = 12,
        .width = 380,
    };

    const placed = geometry.anchor_point(inverted, placement);

    try testing.expectEqual(@as(i32, 300), placed.x);
    try testing.expectEqual(@as(i32, 200), placed.y);
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
