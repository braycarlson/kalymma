const std = @import("std");

const contract = @import("contract.zig");
const event_module = @import("../event.zig");

const assert = std.debug.assert;

const Event = event_module.Event;
const Listener = contract.Listener;

pub const silent = struct {
    pub fn on_subscribe() void {}

    pub fn on_unsubscribe() void {}
};

pub fn EventsType(comptime state: type, comptime hooks: type) type {
    return struct {
        pub fn subscribe(listener: Listener, context: *anyopaque) void {
            assert(state.is_open());
            assert(!state.is_subscribed());

            hooks.on_subscribe();

            state.set_subscriber(listener, context);

            assert(state.is_subscribed());
        }

        pub fn unsubscribe() void {
            hooks.on_unsubscribe();

            state.set_subscriber(null, null);

            assert(!state.is_subscribed());
        }

        pub fn is_subscribed() bool {
            return state.is_subscribed();
        }

        pub fn poll(list: *Event.List) u32 {
            const result = state.drain(list);

            assert(result == list.count);

            return result;
        }
    };
}
