const contract = @import("../contract.zig");
const state = @import("state.zig");

const events = @import("../events.zig").EventsType(state, Recorder);

pub const Error = events.Error;

pub const drops = events.drops;
pub const is_subscribed = events.is_subscribed;
pub const poll = events.poll;
pub const subscribe = events.subscribe;
pub const unsubscribe = events.unsubscribe;

const Recorder = struct {
    pub fn on_subscribe() contract.EventError!void {
        state.record(.subscribe);

        if (state.should_fail(.subscribe)) {
            return contract.EventError.Failed;
        }
    }

    pub fn on_unsubscribe() void {
        state.record(.unsubscribe);
    }
};
