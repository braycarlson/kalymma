const contract = @import("contract.zig");

pub const events = @import("mock/events.zig");
pub const runtime = @import("mock/runtime.zig");
pub const state = @import("mock/state.zig");
pub const surface = @import("mock/surface.zig");

pub const capabilities = contract.Capabilities{
    .input = true,
    .present = true,
};
