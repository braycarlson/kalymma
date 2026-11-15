const builtin = @import("builtin");

const geometry = @import("platform/geometry.zig");
const interface = @import("platform/interface.zig");

pub const Fake = @import("platform/fake.zig");
pub const PlatformError = interface.PlatformError;
pub const Rect = geometry.Rect;

pub const Native = switch (builtin.target.os.tag) {
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("kalymma: unsupported target OS"),
};

pub const assert_backend = interface.assert_backend;
