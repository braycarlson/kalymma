const std = @import("std");

const Call = @import("../fake.zig").Call;

const assert = std.debug.assert;

const Fault = @This();

armed: ?Call = null,

pub fn arm(fault: *Fault, call: Call) void {
    fault.armed = call;

    assert(fault.armed != null);
    assert(fault.is_armed(call));
}

pub fn disarm(fault: *Fault) void {
    fault.armed = null;

    assert(fault.armed == null);
}

pub fn is_armed(fault: *const Fault, call: Call) bool {
    const armed = fault.armed orelse return false;
    return armed == call;
}

const testing = std.testing;

test Fault {
    var fault: Fault = .{};

    try testing.expect(!fault.is_armed(.surface_create));

    fault.arm(.surface_create);

    try testing.expect(fault.is_armed(.surface_create));
    try testing.expect(!fault.is_armed(.surface_show));

    fault.disarm();

    try testing.expect(!fault.is_armed(.surface_create));
}
