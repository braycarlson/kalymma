const std = @import("std");

const event_module = @import("event.zig");
const events_module = @import("events.zig");
const platform = @import("platform.zig");
const runtime_module = @import("runtime.zig");
const surface_module = @import("surface.zig");

pub const Anchor = surface_module.Anchor;
pub const CapacityError = surface_module.CapacityError;
pub const Error = CapacityError || PlatformError || RequestError;
pub const Event = event_module.Event;
pub const Key = event_module.Key;
pub const PlatformError = platform.PlatformError;
pub const Point = event_module.Point;
pub const RequestError = surface_module.RequestError;
pub const Surface = surface_module.Surface;

pub const events = struct {
    pub const poll = events_module.poll;
    pub const subscribe = events_module.subscribe;
    pub const unsubscribe = events_module.unsubscribe;
};

pub const mock = platform.mock;

pub const runtime = struct {
    pub const close = runtime_module.close;
    pub const is_open = runtime_module.is_open;
    pub const open = runtime_module.open;
};

pub const surface = struct {
    pub const Options = surface_module.Options;

    pub const create = surface_module.create;
    pub const destroy = surface_module.destroy;
    pub const frame = surface_module.frame;
    pub const hide = surface_module.hide;
    pub const is_visible = surface_module.is_visible;
    pub const present = surface_module.present;
    pub const show = surface_module.show;

    test Options {
        const status = Options{
            .anchor = .top_right,
            .height = 64,
            .name = "status",
            .width = 256,
        };

        try status.validate();

        try testing.expectEqual(@as(u32, 0), status.margin);
    }

    test create {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });
        defer destroy(status);

        try testing.expectEqual(@as(usize, 256 * 64), frame(status).len);
        try testing.expect(!is_visible(status));
        try testing.expectError(error.SurfaceTooLarge, create(wide));
    }

    test destroy {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });

        destroy(status);

        try testing.expectEqual(@as(usize, 0), frame(status).len);
        try testing.expectError(error.SurfaceUnknown, show(status));
        try testing.expectError(error.SurfaceUnknown, present(status));
    }

    test frame {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });
        defer destroy(status);

        @memset(frame(status), 0xFF102030);

        try testing.expectEqual(@as(u32, 0xFF102030), frame(status)[0]);
    }

    test hide {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });
        defer destroy(status);

        try show(status);

        hide(status);

        try testing.expect(!is_visible(status));
    }

    test is_visible {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });
        defer destroy(status);

        try testing.expect(!is_visible(status));

        try show(status);

        try testing.expect(is_visible(status));
    }

    test present {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });
        defer destroy(status);

        try present(status);
        try present(status);

        try testing.expectEqual(@as(u32, 2), mock.state.count_of(.present));
    }

    test show {
        try open_mock();
        defer runtime.close();

        const status = try create(.{ .height = 64, .name = "status", .width = 256 });
        defer destroy(status);

        try show(status);

        try testing.expect(is_visible(status));
    }
};

pub const limits = struct {
    pub const event_count_max = event_module.event_count_max;
    pub const height_pixels_max = surface_module.height_pixels_max;
    pub const margin_pixels_max = surface_module.margin_pixels_max;
    pub const name_bytes_max = surface_module.name_bytes_max;
    pub const surface_count_max = surface_module.surface_count_max;
    pub const width_pixels_max = surface_module.width_pixels_max;
};

const testing = std.testing;

const wide = surface.Options{
    .height = 64,
    .name = "status",
    .width = limits.width_pixels_max + 1,
};

fn open_mock() !void {
    mock.state.reset();

    try runtime.open();
}

test Error {
    try open_mock();
    defer runtime.close();

    const sized: CapacityError = error.SurfaceTooLarge;
    const failure: Error = sized;

    try testing.expectError(sized, surface.create(wide));
    try testing.expectError(failure, surface.create(wide));

    mock.state.fail(.create);

    const refused: PlatformError = error.SurfaceCreateFailed;

    try testing.expectError(refused, surface.create(.{ .height = 8, .name = "dot", .width = 8 }));
}

test Surface {
    try open_mock();
    defer runtime.close();

    const first = try surface.create(.{ .height = 64, .name = "first", .width = 256 });
    const second = try surface.create(.{ .height = 64, .name = "second", .width = 256 });
    const overflow = surface.Options{ .height = 64, .name = "overflow", .width = 256 };

    try testing.expect(first != second);
    try testing.expectError(error.SurfacesExhausted, surface.create(overflow));

    surface.destroy(first);

    const third = try surface.create(.{ .height = 64, .name = "third", .width = 256 });

    try testing.expect(third != first);

    surface.destroy(second);
    surface.destroy(third);
}

test limits {
    try testing.expect(limits.surface_count_max > 0);
    try testing.expect(limits.event_count_max > 1);
    try testing.expect(limits.margin_pixels_max < limits.width_pixels_max);
}

test "the root surface resolves on the mock backend" {
    testing.refAllDecls(@This());
    testing.refAllDecls(events);
    testing.refAllDecls(limits);
    testing.refAllDecls(runtime);
    testing.refAllDecls(surface);
}
