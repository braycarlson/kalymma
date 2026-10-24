const state = @import("state.zig");

const events = @import("../events.zig").EventsType(state, Recorder);

pub const is_subscribed = events.is_subscribed;
pub const poll = events.poll;
pub const subscribe = events.subscribe;
pub const unsubscribe = events.unsubscribe;

const Recorder = struct {
    pub fn on_subscribe() void {
        state.record(.subscribe);
    }

    pub fn on_unsubscribe() void {
        state.record(.unsubscribe);
    }
};
