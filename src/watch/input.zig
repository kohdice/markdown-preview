const std = @import("std");
const actions = @import("actions.zig");

pub const key_read_buf_size: usize = 16;

const InputPhase = enum { idle, esc, csi, csi_digit };

pub const InputState = struct {
    phase: InputPhase = .idle,
    digit: u8 = 0,

    pub fn feedByte(self: *InputState, b: u8) actions.KeyAction {
        switch (self.phase) {
            .idle => return self.handleKey(b),
            .esc => {
                if (b == '[') {
                    self.phase = .csi;
                    return .none;
                }
                self.phase = .idle;
                return self.handleKey(b);
            },
            .csi => {
                self.phase = .idle;
                return switch (b) {
                    'A' => .scroll_up,
                    'B' => .scroll_down,
                    '5', '6' => blk: {
                        self.phase = .csi_digit;
                        self.digit = b;
                        break :blk .none;
                    },
                    else => .none,
                };
            },
            .csi_digit => {
                self.phase = .idle;
                if (b == '~') {
                    return switch (self.digit) {
                        '5' => .page_up,
                        '6' => .page_down,
                        else => .none,
                    };
                }
                return .none;
            },
        }
    }

    fn handleKey(self: *InputState, b: u8) actions.KeyAction {
        if (b == 0x1b) {
            self.phase = .esc;
            return .none;
        }
        return switch (b) {
            'q' => .quit,
            'k' => .scroll_up,
            'j' => .scroll_down,
            'g' => .scroll_top,
            'G' => .scroll_bottom,
            else => .none,
        };
    }
};

test "InputState single-byte keys" {
    var s: InputState = .{};
    try std.testing.expectEqual(actions.KeyAction.quit, s.feedByte('q'));
    try std.testing.expectEqual(actions.KeyAction.scroll_up, s.feedByte('k'));
    try std.testing.expectEqual(actions.KeyAction.scroll_down, s.feedByte('j'));
    try std.testing.expectEqual(actions.KeyAction.scroll_top, s.feedByte('g'));
    try std.testing.expectEqual(actions.KeyAction.scroll_bottom, s.feedByte('G'));
    try std.testing.expectEqual(actions.KeyAction.none, s.feedByte('x'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState complete arrow sequence in burst" {
    var s: InputState = .{};
    try std.testing.expectEqual(actions.KeyAction.none, s.feedByte(0x1b));
    try std.testing.expectEqual(InputPhase.esc, s.phase);
    try std.testing.expectEqual(actions.KeyAction.none, s.feedByte('['));
    try std.testing.expectEqual(InputPhase.csi, s.phase);
    try std.testing.expectEqual(actions.KeyAction.scroll_up, s.feedByte('A'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState arrow down" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    _ = s.feedByte('[');
    try std.testing.expectEqual(actions.KeyAction.scroll_down, s.feedByte('B'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState PageUp sequence" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    _ = s.feedByte('[');
    try std.testing.expectEqual(actions.KeyAction.none, s.feedByte('5'));
    try std.testing.expectEqual(InputPhase.csi_digit, s.phase);
    try std.testing.expectEqual(actions.KeyAction.page_up, s.feedByte('~'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState PageDown sequence" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    _ = s.feedByte('[');
    _ = s.feedByte('6');
    try std.testing.expectEqual(actions.KeyAction.page_down, s.feedByte('~'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState ESC then regular key processes the key" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    try std.testing.expectEqual(InputPhase.esc, s.phase);
    try std.testing.expectEqual(actions.KeyAction.scroll_down, s.feedByte('j'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState ESC then unknown key is ignored" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    try std.testing.expectEqual(actions.KeyAction.none, s.feedByte('x'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState double ESC: first consumed, second starts new sequence" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    try std.testing.expectEqual(actions.KeyAction.none, s.feedByte(0x1b));
    try std.testing.expectEqual(InputPhase.esc, s.phase);
}
