const std = @import("std");

const contract = @import("../../contract.zig");
const geometry = @import("../../geometry.zig");

const assert = std.debug.assert;

const Anchor = contract.Anchor;
const Key = contract.Key;
const Rect = geometry.Rect;

pub const byte_order_little: u8 = 0x6c;
pub const protocol_major: u16 = 11;
pub const protocol_minor: u16 = 0;

pub const setup_failed: u8 = 0;
pub const setup_success: u8 = 1;
pub const setup_authenticate: u8 = 2;

pub const opcode_create_window: u8 = 1;
pub const opcode_destroy_window: u8 = 4;
pub const opcode_map_window: u8 = 8;
pub const opcode_unmap_window: u8 = 10;
pub const opcode_configure_window: u8 = 12;
pub const opcode_intern_atom: u8 = 16;
pub const opcode_get_property: u8 = 20;
pub const opcode_set_input_focus: u8 = 42;
pub const opcode_create_gc: u8 = 55;
pub const opcode_free_gc: u8 = 60;
pub const opcode_put_image: u8 = 72;
pub const opcode_create_colormap: u8 = 78;

pub const reply_error: u8 = 0;
pub const reply_normal: u8 = 1;

pub const event_key_press: u8 = 2;
pub const event_button_press: u8 = 4;
pub const event_button_release: u8 = 5;
pub const event_motion_notify: u8 = 6;
pub const event_leave_notify: u8 = 8;
pub const event_focus_out: u8 = 10;
pub const event_expose: u8 = 12;

pub const event_bytes: u32 = 32;

pub const class_input_output: u16 = 1;
pub const class_true_color: u8 = 4;

pub const attribute_back_pixel: u32 = 1 << 1;
pub const attribute_border_pixel: u32 = 1 << 3;
pub const attribute_override_redirect: u32 = 1 << 9;
pub const attribute_event_mask: u32 = 1 << 11;
pub const attribute_colormap: u32 = 1 << 13;

pub const mask_key_press: u32 = 1 << 0;
pub const mask_button_press: u32 = 1 << 2;
pub const mask_button_release: u32 = 1 << 3;
pub const mask_leave_window: u32 = 1 << 5;
pub const mask_pointer_motion: u32 = 1 << 6;
pub const mask_exposure: u32 = 1 << 15;
pub const mask_focus_change: u32 = 1 << 21;

pub const configure_x: u16 = 1 << 0;
pub const configure_y: u16 = 1 << 1;
pub const configure_width: u16 = 1 << 2;
pub const configure_height: u16 = 1 << 3;
pub const configure_stack_mode: u16 = 1 << 6;

pub const stack_above: u32 = 0;

pub const colormap_alloc_none: u8 = 0;

pub const format_z_pixmap: u8 = 2;

pub const revert_to_parent: u8 = 2;

pub const button_left: u8 = 1;

pub const keycode_offset: u32 = 8;

pub const key_escape: u32 = 9;
pub const key_enter: u32 = 36;
pub const key_space: u32 = 65;
pub const key_keypad_enter: u32 = 104;
pub const key_up: u32 = 111;
pub const key_left: u32 = 113;
pub const key_right: u32 = 114;
pub const key_down: u32 = 116;

pub const auth_name = "MIT-MAGIC-COOKIE-1";

pub const workarea_atom = "_NET_WORKAREA";

comptime {
    assert(byte_order_little == 'l');
    assert(event_bytes == 32);
    assert(keycode_offset == 8);
    assert(auth_name.len == 18);
}

pub fn anchor_point(work: Rect, width: i32, height: i32, margin: i32, anchor: Anchor) Rect {
    const origin = geometry.anchor_point(work, width, height, margin, anchor);

    return Rect{ .height = height, .width = width, .x = origin.x, .y = origin.y };
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

pub fn pad(size: u32) u32 {
    const result = (size + 3) & ~@as(u32, 3);

    assert(result >= size);
    assert(result % 4 == 0);

    return result;
}

const testing = std.testing;

test "an anchored surface keeps the size it was asked for" {
    const work = Rect{ .height = 1040, .width = 1920, .x = 0, .y = 0 };

    const placed = anchor_point(work, 380, 220, 12, .bottom_right);

    try testing.expectEqual(@as(i32, 380), placed.width);
    try testing.expectEqual(@as(i32, 220), placed.height);
    try testing.expectEqual(@as(i32, 1528), placed.x);
    try testing.expectEqual(@as(i32, 808), placed.y);
}

test "an X keycode outside the overlay vocabulary maps to other" {
    try testing.expectEqual(Key.escape, to_key(key_escape));
    try testing.expectEqual(Key.enter, to_key(key_enter));
    try testing.expectEqual(Key.enter, to_key(key_keypad_enter));
    try testing.expectEqual(Key.space, to_key(key_space));
    try testing.expectEqual(Key.left, to_key(key_left));
    try testing.expectEqual(Key.right, to_key(key_right));
    try testing.expectEqual(Key.up, to_key(key_up));
    try testing.expectEqual(Key.down, to_key(key_down));
    try testing.expectEqual(Key.other, to_key(38));
}

test "padding rounds up to the next word" {
    try testing.expectEqual(@as(u32, 0), pad(0));
    try testing.expectEqual(@as(u32, 4), pad(1));
    try testing.expectEqual(@as(u32, 4), pad(4));
    try testing.expectEqual(@as(u32, 8), pad(5));
}
