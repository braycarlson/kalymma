const std = @import("std");

const event_module = @import("event.zig");
const monitor_module = @import("monitor.zig");
const platform = @import("platform.zig");
const runtime_module = @import("runtime.zig");
const shade_module = @import("shade.zig");
const surface_module = @import("surface.zig");

pub const Anchor = surface_module.Anchor;
pub const CapacityError = surface_module.CapacityError || shade_module.CapacityError;
pub const Cursor = shade_module.Cursor;
pub const Error = CapacityError || PlatformError || RequestError;
pub const Event = event_module.Event;
pub const Fake = platform.Fake;
pub const Key = event_module.Key;
pub const Monitor = monitor_module.Monitor;
pub const PlatformError = platform.PlatformError;
pub const Point = event_module.Point;
pub const Rect = platform.Rect;
pub const RequestError = surface_module.RequestError || shade_module.RequestError;
pub const Runtime = RuntimeType(platform.Native);
pub const RuntimeType = runtime_module.RuntimeType;
pub const Shade = shade_module.Shade;
pub const Surface = surface_module.Surface;

pub const limits = struct {
    pub const event_count_max = event_module.count_max;
    pub const height_pixels_max = surface_module.height_pixels_max;
    pub const margin_pixels_max = surface_module.margin_pixels_max;
    pub const monitor_count_max = monitor_module.count_max;
    pub const monitor_name_bytes_max = monitor_module.name_bytes_max;
    pub const name_bytes_max = surface_module.name_bytes_max;
    pub const shade_count_max = shade_module.count_max;
    pub const surface_count_max = surface_module.count_max;
    pub const width_pixels_max = surface_module.width_pixels_max;
};

const testing = std.testing;

const FakeRuntime = RuntimeType(Fake);

const left_monitor = Rect{ .height = 1080, .width = 1920, .x = 0, .y = 0 };

const wide = Surface.Options{
    .height = 64,
    .name = "status",
    .width = limits.width_pixels_max + 1,
};

fn open_fake() !*FakeRuntime {
    const runtime = try testing.allocator.create(FakeRuntime);
    errdefer testing.allocator.destroy(runtime);

    try runtime.init(.{});

    return runtime;
}

fn close_fake(runtime: *FakeRuntime) void {
    runtime.deinit();
    testing.allocator.destroy(runtime);
}

test Error {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const sized: CapacityError = error.SurfaceTooLarge;
    const failure: Error = sized;

    try testing.expectError(sized, runtime.surface_create(wide));
    try testing.expectError(failure, runtime.surface_create(wide));

    runtime.platform.fault.arm(.surface_create);

    const refused: PlatformError = error.SurfaceCreateFailed;
    const dot = Surface.Options{ .height = 8, .name = "dot", .width = 8 };

    try testing.expectError(refused, runtime.surface_create(dot));
}

test Fake {
    const runtime = try testing.allocator.create(RuntimeType(Fake));
    defer testing.allocator.destroy(runtime);

    try runtime.init(.{});
    defer runtime.deinit();

    const status = try runtime.surface_create(.{ .height = 8, .name = "status", .width = 8 });

    runtime.platform.fault.arm(.surface_show);

    try testing.expectError(error.SurfaceShowFailed, runtime.surface_show(status));

    runtime.platform.inject(status, .{ .key_down = .escape });

    var list = Event.List.init();

    try testing.expectEqual(@as(u32, 1), runtime.events_poll(&list));
    try testing.expectEqual(Key.escape, list.slice()[0].input.key_down);
}

test Monitor {
    const primary = Monitor.init("DP-4", .{ .height = 1080, .width = 1920, .x = 1920, .y = 0 });

    try testing.expectEqualStrings("DP-4", primary.get_name());
    try testing.expectEqual(@as(i32, 1920), primary.rect.x);
}

test Rect {
    const region = Rect{ .height = 300, .width = 400, .x = -100, .y = 50 };

    try testing.expectEqual(@as(i32, -100), region.x);
    try testing.expectEqual(@as(i32, 400), region.width);
}

test Shade {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const first = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });
    const second = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });

    try testing.expect(first != second);

    runtime.shade_destroy(first);

    const third = try runtime.shade_create(.{ .color = 0x80000000, .rect = left_monitor });

    try testing.expect(third != first);

    runtime.shade_destroy(second);
    runtime.shade_destroy(third);
}

test Surface {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const first = try runtime.surface_create(.{ .height = 64, .name = "first", .width = 256 });
    const second = try runtime.surface_create(.{ .height = 64, .name = "second", .width = 256 });
    const overflow = Surface.Options{ .height = 64, .name = "overflow", .width = 256 };

    try testing.expect(first != second);
    try testing.expectError(error.SurfacesExhausted, runtime.surface_create(overflow));

    runtime.surface_destroy(first);

    const third = try runtime.surface_create(.{ .height = 64, .name = "third", .width = 256 });

    try testing.expect(third != first);

    runtime.surface_destroy(second);
    runtime.surface_destroy(third);
}

test limits {
    try testing.expect(limits.monitor_count_max > 0);
    try testing.expect(limits.monitor_name_bytes_max > 0);
    try testing.expect(limits.shade_count_max >= limits.monitor_count_max);
    try testing.expect(limits.surface_count_max > 0);
    try testing.expect(limits.event_count_max > 1);
    try testing.expect(limits.margin_pixels_max < limits.width_pixels_max);
}

test "monitors_list" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    var found = Monitor.List.init();

    try testing.expectEqual(@as(u32, 1), runtime.monitors_list(&found));
    try testing.expectEqualStrings("fake", found.slice()[0].get_name());
    try testing.expectEqual(@as(i32, 1920), found.slice()[0].rect.width);
}

test "Surface.Options" {
    const status = Surface.Options{
        .anchor = .top_right,
        .height = 64,
        .name = "status",
        .width = 256,
    };

    try status.validate();

    try testing.expectEqual(@as(u32, 0), status.margin);
}

test "surface_create" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    try testing.expectEqual(@as(usize, 256 * 64), runtime.surface_frame(status).len);
    try testing.expect(!runtime.surface_is_visible(status));
    try testing.expectError(error.SurfaceTooLarge, runtime.surface_create(wide));
}

test "surface_destroy" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });

    runtime.surface_destroy(status);

    try testing.expectEqual(@as(usize, 0), runtime.surface_frame(status).len);
    try testing.expectError(error.SurfaceUnknown, runtime.surface_show(status));
    try testing.expectError(error.SurfaceUnknown, runtime.surface_present(status));
}

test "surface_frame" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    @memset(runtime.surface_frame(status), 0xFF102030);

    try testing.expectEqual(@as(u32, 0xFF102030), runtime.surface_frame(status)[0]);
}

test "surface_hide" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    try runtime.surface_show(status);

    runtime.surface_hide(status);

    try testing.expect(!runtime.surface_is_visible(status));
}

test "surface_is_visible" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    try testing.expect(!runtime.surface_is_visible(status));

    try runtime.surface_show(status);

    try testing.expect(runtime.surface_is_visible(status));
}

test "surface_present" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    try runtime.surface_present(status);
    try runtime.surface_present(status);

    try testing.expectEqual(@as(u32, 2), runtime.platform.count_of(.surface_present));
}

test "surface_show" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
    defer runtime.surface_destroy(status);

    try runtime.surface_show(status);

    try testing.expect(runtime.surface_is_visible(status));
}

test "Shade.Options" {
    const dim = Shade.Options{ .color = 0xB3000000, .rect = left_monitor };

    try dim.validate();

    try testing.expect(!dim.interactive);
}

test "shade_create" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const dim = try runtime.shade_create(.{ .color = 0xB3000000, .rect = left_monitor });
    defer runtime.shade_destroy(dim);

    try testing.expectEqual(@as(u32, 0xB3000000), runtime.platform.shade_of(dim).?.color);
    try testing.expectError(error.ShadeEmpty, runtime.shade_create(.{ .color = 0, .rect = .{} }));
}

test "shade_destroy" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const dim = try runtime.shade_create(.{ .color = 0xB3000000, .rect = left_monitor });

    runtime.shade_destroy(dim);

    try testing.expect(runtime.platform.shade_of(dim) == null);
    try testing.expectError(error.ShadeUnknown, runtime.shade_fill(dim, 0x80000000));
}

test "shade_fill" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const dim = try runtime.shade_create(.{ .color = 0xB3000000, .rect = left_monitor });
    defer runtime.shade_destroy(dim);

    try runtime.shade_fill(dim, 0x4D000000);

    try testing.expectEqual(@as(u32, 0x4D000000), runtime.platform.shade_of(dim).?.color);
}

test "shade_place" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const dim = try runtime.shade_create(.{ .color = 0xB3000000, .rect = left_monitor });
    defer runtime.shade_destroy(dim);

    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 200 };

    try runtime.shade_place(dim, region);

    try testing.expectEqual(region, runtime.platform.shade_of(dim).?.rect);
    try testing.expectError(error.ShadeEmpty, runtime.shade_place(dim, .{ .width = 400 }));
}

test "shade_set_cursor" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    const options = Shade.Options{ .color = 0x26000000, .interactive = true, .rect = left_monitor };
    const catcher = try runtime.shade_create(options);
    defer runtime.shade_destroy(catcher);

    try testing.expectEqual(Cursor.crosshair, runtime.platform.shade_of(catcher).?.cursor);

    try runtime.shade_set_cursor(catcher, .resize_east_west);

    try testing.expectEqual(Cursor.resize_east_west, runtime.platform.shade_of(catcher).?.cursor);
}

test "tint_apply" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    runtime.platform.set_tint_supported(true);

    try runtime.tint_apply(0x80000000);

    try testing.expectEqual(@as(?u32, 0x80000000), runtime.platform.tint_of());

    runtime.platform.fault.arm(.tint_apply);

    try testing.expectError(error.TintFailed, runtime.tint_apply(0x4D000000));
    try testing.expectEqual(@as(?u32, 0x80000000), runtime.platform.tint_of());
}

test "tint_clear" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    runtime.platform.set_tint_supported(true);

    try runtime.tint_apply(0x80000000);

    runtime.tint_clear();
    runtime.tint_clear();

    try testing.expect(runtime.platform.tint_of() == null);
}

test "tint_is_supported" {
    const runtime = try open_fake();
    defer close_fake(runtime);

    try testing.expect(!runtime.tint_is_supported());

    runtime.platform.set_tint_supported(true);

    try testing.expect(runtime.tint_is_supported());
}

test "the root surface resolves on the fake backend" {
    testing.refAllDecls(@This());
    testing.refAllDecls(limits);
    testing.refAllDecls(FakeRuntime);
}
