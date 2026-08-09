const contract = @import("contract.zig");

pub const display = @import("linux/display.zig");
pub const events = @import("linux/events.zig");
pub const runtime = @import("linux/runtime.zig");
pub const state = @import("linux/state.zig");
pub const surface = @import("linux/surface.zig");

pub const capabilities = contract.Capabilities{
    .input = true,
    .present = true,
};
