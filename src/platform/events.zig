const std = @import("std");

const contract = @import("contract.zig");

const assert = std.debug.assert;

const EventCallback = contract.EventCallback;
const EventError = contract.EventError;
const EventList = contract.EventList;

pub const silent = struct {
    pub fn on_subscribe() EventError!void {}

    pub fn on_unsubscribe() void {}
};

pub fn EventsType(comptime state: type, comptime hooks: type) type {
    return struct {
        pub const Error = EventError;

        pub fn subscribe(callback: EventCallback, context: ?*anyopaque) Error!void {
            try hooks.on_subscribe();

            if (!state.is_open()) {
                return Error.NotOpen;
            }

            if (state.is_subscribed()) {
                return Error.AlreadySubscribed;
            }

            state.set_subscriber(callback, context);

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

        pub fn poll(list: *EventList) u32 {
            const result = state.drain(list);

            assert(result == list.count);

            return result;
        }

        pub fn drops() u32 {
            return state.drops();
        }
    };
}
