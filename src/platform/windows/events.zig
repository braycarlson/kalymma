const state = @import("state.zig");

const events_module = @import("../events.zig");

const events = events_module.EventsType(state, events_module.silent);

pub const Error = events.Error;

pub const drops = events.drops;
pub const is_subscribed = events.is_subscribed;
pub const poll = events.poll;
pub const subscribe = events.subscribe;
pub const unsubscribe = events.unsubscribe;
