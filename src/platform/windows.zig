const contract = @import("contract.zig");

pub const events = @import("windows/events.zig");
pub const runtime = @import("windows/runtime.zig");
pub const state = @import("windows/state.zig");
pub const surface = @import("windows/surface.zig");

pub const capabilities = contract.Capabilities{
    .input = true,
    .present = true,
};
