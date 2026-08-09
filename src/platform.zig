const build_options = @import("build_options");
const builtin = @import("builtin");

const contract = @import("platform/contract.zig");

pub const Anchor = contract.Anchor;
pub const Capabilities = contract.Capabilities;
pub const Event = contract.Event;
pub const EventCallback = contract.EventCallback;
pub const EventError = contract.EventError;
pub const EventList = contract.EventList;
pub const Handle = contract.Handle;
pub const InputEvent = contract.InputEvent;
pub const InputKind = contract.InputKind;
pub const Key = contract.Key;
pub const Point = contract.Point;
pub const RuntimeConfig = contract.RuntimeConfig;
pub const RuntimeError = contract.RuntimeError;
pub const SurfaceConfig = contract.SurfaceConfig;
pub const SurfaceError = contract.SurfaceError;

pub const events_max = contract.events_max;
pub const height_max = contract.height_max;
pub const margin_max = contract.margin_max;
pub const name_bytes_max = contract.name_bytes_max;
pub const scale_max = contract.scale_max;
pub const surfaces_max = contract.surfaces_max;
pub const width_max = contract.width_max;

pub const backend = if (build_options.backend_mock)
    @import("platform/mock.zig")
else switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("kalymma: unsupported target OS"),
};

pub const mock = if (build_options.backend_mock)
    backend
else
    @compileError("kalymma: mock surface requires -Dbackend=mock");

pub const capabilities: Capabilities = backend.capabilities;

comptime {
    contract.assert_backend(backend);
}
