const std = @import("std");

const assert = std.debug.assert;

pub const ATOM = u16;
pub const BOOL = i32;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const WPARAM = usize;

pub const HBITMAP = *opaque {};
pub const HBRUSH = *opaque {};
pub const HCURSOR = *opaque {};
pub const HDC = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HICON = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMENU = *opaque {};
pub const HMONITOR = *opaque {};
pub const HWND = *opaque {};

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const CS_VREDRAW: u32 = 0x0001;
pub const CS_HREDRAW: u32 = 0x0002;

pub const WS_POPUP: u32 = 0x80000000;

pub const WS_EX_TOPMOST: u32 = 0x00000008;
pub const WS_EX_TOOLWINDOW: u32 = 0x00000080;
pub const WS_EX_LAYERED: u32 = 0x00080000;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const SWP_SHOWWINDOW: u32 = 0x0040;

pub const ULW_ALPHA: u32 = 0x00000002;

pub const AC_SRC_OVER: u8 = 0x00;
pub const AC_SRC_ALPHA: u8 = 0x01;

pub const TME_LEAVE: u32 = 0x00000002;

pub const DIB_RGB_COLORS: u32 = 0;
pub const BI_RGB: u32 = 0;

pub const GWLP_USERDATA: i32 = -21;

pub const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;

pub const ERROR_CLASS_ALREADY_EXISTS: u32 = 1410;

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_MOUSELEAVE: u32 = 0x02A3;
pub const WM_APP: u32 = 0x8000;

pub const VK_RETURN: u32 = 0x0D;
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_SPACE: u32 = 0x20;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;

pub const IDC_ARROW: [*:0]align(1) const u16 = @ptrFromInt(32512);

pub const HWND_TOPMOST: HWND = @ptrFromInt(std.math.maxInt(usize));
pub const HWND_MESSAGE: HWND = @ptrFromInt(std.math.maxInt(usize) - 2);

comptime {
    assert(WM_APP == 0x8000);
    assert(ULW_ALPHA == 2);
    assert(GWLP_USERDATA == -21);
}

pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

pub const SIZE = extern struct {
    cx: i32 = 0,
    cy: i32 = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: u32 = 0,
    pt: POINT = .{},
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = 0,
    style: u32 = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: ?[*:0]const u16 = null,
    hIconSm: ?HICON = null,
};

pub const MONITORINFO = extern struct {
    cbSize: u32 = 0,
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = 0,
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 0,
    biBitCount: u16 = 0,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [4]u8 = @splat(0),
};

pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = AC_SRC_OVER,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = AC_SRC_ALPHA,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = 0,
    dwFlags: u32 = 0,
    hwndTrack: ?HWND = null,
    dwHoverTime: u32 = 0,
};

comptime {
    assert(@sizeOf(MONITORINFO) == 40);
    assert(@offsetOf(MONITORINFO, "rcWork") == 20);
    assert(@sizeOf(BITMAPINFOHEADER) == 40);
    assert(@sizeOf(BLENDFUNCTION) == 4);
}

pub const SRWLOCK = extern struct {
    ptr: ?*anyopaque = null,
};

pub extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn TryAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) u8;

pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;

pub extern "user32" fn UnregisterClassW(
    class: [*:0]const u16,
    instance: ?HINSTANCE,
) callconv(.winapi) BOOL;

pub extern "user32" fn CreateWindowExW(
    style_extended: u32,
    class: ?[*:0]const u16,
    title: ?[*:0]const u16,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    parameter: ?*anyopaque,
) callconv(.winapi) ?HWND;

pub extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn DefWindowProcW(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;

pub extern "user32" fn GetMessageW(
    message: *MSG,
    window: ?HWND,
    filter_min: u32,
    filter_max: u32,
) callconv(.winapi) BOOL;

pub extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;

pub extern "user32" fn SendMessageW(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;

pub extern "user32" fn PostMessageW(
    window: ?HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) BOOL;

pub extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowPos(
    window: HWND,
    insert_after: ?HWND,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    flags: u32,
) callconv(.winapi) BOOL;

pub extern "user32" fn SetForegroundWindow(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(window: HWND, rect: *RECT) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowLongPtrW(
    window: HWND,
    index: i32,
    value: isize,
) callconv(.winapi) isize;

pub extern "user32" fn GetWindowLongPtrW(window: HWND, index: i32) callconv(.winapi) isize;

pub extern "user32" fn GetDC(window: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(window: ?HWND, context: HDC) callconv(.winapi) i32;

pub extern "user32" fn UpdateLayeredWindow(
    window: HWND,
    destination_context: ?HDC,
    destination: ?*const POINT,
    size: ?*const SIZE,
    source_context: ?HDC,
    source: ?*const POINT,
    key: u32,
    blend: ?*const BLENDFUNCTION,
    flags: u32,
) callconv(.winapi) BOOL;

pub extern "user32" fn TrackMouseEvent(track: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(window: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(point: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn MonitorFromPoint(
    point: POINT,
    flags: u32,
) callconv(.winapi) ?HMONITOR;

pub extern "user32" fn GetMonitorInfoW(
    monitor: HMONITOR,
    info: *MONITORINFO,
) callconv(.winapi) BOOL;

pub extern "user32" fn LoadCursorW(
    instance: ?HINSTANCE,
    name: [*:0]align(1) const u16,
) callconv(.winapi) ?HCURSOR;

pub extern "gdi32" fn CreateCompatibleDC(context: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(context: HDC) callconv(.winapi) BOOL;

pub extern "gdi32" fn CreateDIBSection(
    context: ?HDC,
    info: *const BITMAPINFO,
    usage: u32,
    bits: *?*anyopaque,
    section: ?*anyopaque,
    offset: u32,
) callconv(.winapi) ?HBITMAP;

pub extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn SelectObject(context: HDC, object: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
