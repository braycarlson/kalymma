const platform = @import("platform.zig");

pub const Anchor = platform.Anchor;
pub const Capabilities = platform.Capabilities;
pub const Event = platform.Event;
pub const EventCallback = platform.EventCallback;
pub const EventError = platform.EventError;
pub const EventList = platform.EventList;
pub const Handle = platform.Handle;
pub const InputEvent = platform.InputEvent;
pub const InputKind = platform.InputKind;
pub const Key = platform.Key;
pub const Point = platform.Point;
pub const RuntimeConfig = platform.RuntimeConfig;
pub const RuntimeError = platform.RuntimeError;
pub const SurfaceConfig = platform.SurfaceConfig;
pub const SurfaceError = platform.SurfaceError;

pub const capabilities = platform.capabilities;

pub const mock = platform.mock;

pub const events_max = platform.events_max;
pub const height_max = platform.height_max;
pub const margin_max = platform.margin_max;
pub const name_bytes_max = platform.name_bytes_max;
pub const scale_max = platform.scale_max;
pub const surfaces_max = platform.surfaces_max;
pub const width_max = platform.width_max;

pub const runtime = struct {
    pub const Error = RuntimeError;

    pub fn open(config: RuntimeConfig) Error!void {
        try platform.backend.runtime.open(config);
    }

    pub fn close() void {
        platform.backend.runtime.close();
    }

    pub fn is_open() bool {
        return platform.backend.runtime.is_open();
    }
};

pub const surface = struct {
    pub const Error = SurfaceError;

    pub fn create(config: SurfaceConfig) Error!Handle {
        return try platform.backend.surface.create(&config);
    }

    pub fn destroy(handle: Handle) void {
        platform.backend.surface.destroy(handle);
    }

    pub fn show(handle: Handle) Error!void {
        try platform.backend.surface.show(handle);
    }

    pub fn hide(handle: Handle) void {
        platform.backend.surface.hide(handle);
    }

    pub fn is_visible(handle: Handle) bool {
        return platform.backend.surface.is_visible(handle);
    }

    pub fn frame(handle: Handle) []u32 {
        return platform.backend.surface.frame(handle);
    }

    pub fn present(handle: Handle) Error!void {
        try platform.backend.surface.present(handle);
    }

    pub fn scale(handle: Handle) u32 {
        return platform.backend.surface.scale(handle);
    }
};

pub const events = struct {
    pub const Error = EventError;
    pub const Callback = EventCallback;

    pub fn subscribe(callback: Callback, context: ?*anyopaque) Error!void {
        try platform.backend.events.subscribe(callback, context);
    }

    pub fn unsubscribe() void {
        platform.backend.events.unsubscribe();
    }

    pub fn is_subscribed() bool {
        return platform.backend.events.is_subscribed();
    }

    pub fn poll(list: *EventList) u32 {
        return platform.backend.events.poll(list);
    }

    pub fn drops() u32 {
        return platform.backend.events.drops();
    }
};
