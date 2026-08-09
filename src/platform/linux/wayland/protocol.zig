const std = @import("std");

const contract = @import("../../contract.zig");

const assert = std.debug.assert;

const Anchor = contract.Anchor;
const Key = contract.Key;

pub const display_id: u32 = 1;

pub const interface_compositor = "wl_compositor";
pub const interface_layer_shell = "zwlr_layer_shell_v1";
pub const interface_seat = "wl_seat";
pub const interface_shm = "wl_shm";

pub const version_compositor: u32 = 4;
pub const version_layer_shell: u32 = 1;
pub const version_seat: u32 = 5;
pub const version_shm: u32 = 1;

pub const display_sync: u16 = 0;
pub const display_get_registry: u16 = 1;

pub const display_error: u16 = 0;
pub const display_delete_id: u16 = 1;

pub const registry_bind: u16 = 0;

pub const registry_global: u16 = 0;
pub const registry_global_remove: u16 = 1;

pub const callback_done: u16 = 0;

pub const compositor_create_surface: u16 = 0;

pub const shm_create_pool: u16 = 0;

pub const pool_create_buffer: u16 = 0;
pub const pool_destroy: u16 = 1;

pub const buffer_destroy: u16 = 0;

pub const surface_destroy: u16 = 0;
pub const surface_attach: u16 = 1;
pub const surface_damage: u16 = 2;
pub const surface_commit: u16 = 6;
pub const surface_set_buffer_scale: u16 = 8;

pub const layer_shell_get_layer_surface: u16 = 0;
pub const layer_shell_destroy: u16 = 1;

pub const layer_surface_set_size: u16 = 0;
pub const layer_surface_set_anchor: u16 = 1;
pub const layer_surface_set_exclusive_zone: u16 = 2;
pub const layer_surface_set_margin: u16 = 3;
pub const layer_surface_set_keyboard_interactivity: u16 = 4;
pub const layer_surface_ack_configure: u16 = 6;
pub const layer_surface_destroy: u16 = 7;

pub const layer_surface_configure: u16 = 0;
pub const layer_surface_closed: u16 = 1;

pub const seat_get_pointer: u16 = 0;
pub const seat_get_keyboard: u16 = 1;

pub const seat_capabilities: u16 = 0;
pub const seat_name: u16 = 1;

pub const pointer_enter: u16 = 0;
pub const pointer_leave: u16 = 1;
pub const pointer_motion: u16 = 2;
pub const pointer_button: u16 = 3;

pub const keyboard_keymap: u16 = 0;
pub const keyboard_enter: u16 = 1;
pub const keyboard_leave: u16 = 2;
pub const keyboard_key: u16 = 3;

pub const seat_capability_pointer: u32 = 1;
pub const seat_capability_keyboard: u32 = 2;

pub const layer_overlay: u32 = 3;

pub const anchor_top: u32 = 1;
pub const anchor_bottom: u32 = 2;
pub const anchor_left: u32 = 4;
pub const anchor_right: u32 = 8;

pub const keyboard_interactivity_on_demand: u32 = 2;

pub const format_argb8888: u32 = 0;

pub const button_left: u32 = 0x110;
pub const button_state_released: u32 = 0;
pub const button_state_pressed: u32 = 1;

pub const key_escape: u32 = 1;
pub const key_enter: u32 = 28;
pub const key_space: u32 = 57;
pub const key_keypad_enter: u32 = 96;
pub const key_up: u32 = 103;
pub const key_left: u32 = 105;
pub const key_right: u32 = 106;
pub const key_down: u32 = 108;

comptime {
    assert(display_id == 1);
    assert(surface_commit == 6);
    assert(layer_overlay == 3);
    assert(anchor_top | anchor_bottom | anchor_left | anchor_right == 15);
    assert(format_argb8888 == 0);
}

pub fn to_anchor_bits(anchor: Anchor) u32 {
    const result = switch (anchor) {
        .bottom_right => anchor_bottom | anchor_right,
        .top_right => anchor_top | anchor_right,
        .center => 0,
    };

    return result;
}

pub fn to_key(code: u32) Key {
    const result: Key = switch (code) {
        key_escape => .escape,
        key_enter, key_keypad_enter => .enter,
        key_space => .space,
        key_left => .left,
        key_right => .right,
        key_up => .up,
        key_down => .down,
        else => .other,
    };

    assert(result.is_valid());

    return result;
}

const testing = std.testing;

test "every anchor maps to the layer shell edge bits it names" {
    try testing.expectEqual(anchor_bottom | anchor_right, to_anchor_bits(.bottom_right));
    try testing.expectEqual(anchor_top | anchor_right, to_anchor_bits(.top_right));
    try testing.expectEqual(@as(u32, 0), to_anchor_bits(.center));
}

test "an evdev code outside the overlay vocabulary maps to other" {
    try testing.expectEqual(Key.escape, to_key(key_escape));
    try testing.expectEqual(Key.enter, to_key(key_enter));
    try testing.expectEqual(Key.enter, to_key(key_keypad_enter));
    try testing.expectEqual(Key.space, to_key(key_space));
    try testing.expectEqual(Key.left, to_key(key_left));
    try testing.expectEqual(Key.right, to_key(key_right));
    try testing.expectEqual(Key.up, to_key(key_up));
    try testing.expectEqual(Key.down, to_key(key_down));
    try testing.expectEqual(Key.other, to_key(30));
}
