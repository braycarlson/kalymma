const std = @import("std");

const geometry = @import("geometry.zig");
const interface = @import("interface.zig");
const shade_module = @import("../shade.zig");

const assert = std.debug.assert;

const CapacityError = shade_module.CapacityError;
const Cursor = shade_module.Cursor;
const Options = Shade.Options;
const PlatformError = interface.PlatformError;
const Rect = geometry.Rect;
const RequestError = shade_module.RequestError;
const Shade = shade_module.Shade;
const ShadeRequest = interface.ShadeRequest;

pub fn ShadesType(
    comptime State: type,
    comptime submit: fn (*State, ShadeRequest, u16) bool,
) type {
    return struct {
        pub fn create(
            state: *State,
            options: *const Options,
        ) (CapacityError || PlatformError)!Shade {
            assert(state.is_open());
            assert(options.is_valid());

            const shade = try state.acquire_shade(options);

            if (!submit(state, .create, shade_module.unpack(shade).index)) {
                state.release_shade(shade);

                return error.ShadeCreateFailed;
            }

            assert(state.has_shade(shade));

            return shade;
        }

        pub fn destroy(state: *State, shade: Shade) void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(shade_module.unpack(shade).index < shade_module.count_max);

            if (!state.has_shade(shade)) {
                return;
            }

            if (state.is_open()) {
                _ = submit(state, .destroy, shade_module.unpack(shade).index);
            }

            state.release_shade(shade);

            assert(!state.has_shade(shade));
        }

        pub fn fill(state: *State, shade: Shade, color: u32) (PlatformError || RequestError)!void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(state.is_open());

            const previous = state.recolor_shade(shade, color) orelse return error.ShadeUnknown;

            if (!submit(state, .fill, shade_module.unpack(shade).index)) {
                _ = state.recolor_shade(shade, previous);

                return error.ShadeUpdateFailed;
            }
        }

        pub fn place(state: *State, shade: Shade, rect: Rect) (PlatformError || RequestError)!void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(state.is_open());

            const previous = state.move_shade(shade, rect) orelse return error.ShadeUnknown;

            if (!submit(state, .place, shade_module.unpack(shade).index)) {
                _ = state.move_shade(shade, previous);

                return error.ShadeUpdateFailed;
            }
        }

        pub fn set_cursor(
            state: *State,
            shade: Shade,
            cursor: Cursor,
        ) (PlatformError || RequestError)!void {
            assert(shade_module.unpack(shade).generation > 0);
            assert(state.is_open());

            const previous = state.change_shade_cursor(shade, cursor) orelse {
                return error.ShadeUnknown;
            };

            if (!submit(state, .cursor, shade_module.unpack(shade).index)) {
                _ = state.change_shade_cursor(shade, previous);

                return error.ShadeUpdateFailed;
            }
        }
    };
}
