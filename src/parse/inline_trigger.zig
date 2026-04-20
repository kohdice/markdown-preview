const std = @import("std");

// `&` is a forward-looking trigger: the current inline parser does not
// dispatch on entity references (CommonMark 0.31.2 §6.5), but including
// it here keeps the trivial-paragraph bypass correct if entity support
// lands later. See `.plans/refactor_phase8.md` §Findings.
const fast_triggers: []const u8 = "\\`*_~<!&][";

const bare_url_marker: []const u8 = "://";

pub fn isTrivial(lines: []const []const u8) bool {
    for (lines, 0..) |line, idx| {
        if (std.mem.indexOfAny(u8, line, fast_triggers) != null) return false;

        if (idx + 1 < lines.len and endsWithHardBreakSpaces(line)) return false;

        if (std.mem.indexOfPos(u8, line, 0, bare_url_marker) != null) return false;
    }

    return true;
}

fn endsWithHardBreakSpaces(line: []const u8) bool {
    if (line.len < 2) return false;
    var seen: usize = 0;
    var i: usize = line.len;
    while (i > 0) : (i -= 1) {
        if (line[i - 1] != ' ') return seen >= 2;
        seen += 1;
        if (seen >= 2) return true;
    }
    return seen >= 2;
}

test "isTrivial returns true for empty line slice" {
    try std.testing.expect(isTrivial(&.{}));
}

test "isTrivial returns true for a single plain ASCII line" {
    const lines = [_][]const u8{"Plain text without any markup"};
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial returns true for multi-line all-plain prose" {
    const lines = [_][]const u8{
        "The quick brown fox",
        "jumps over the lazy dog",
        "three times in total",
    };
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial returns true for CJK-only paragraph" {
    const lines = [_][]const u8{"日本語のみの段落でも trigger はない"};
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial rejects line with emphasis asterisk" {
    const lines = [_][]const u8{"contains *emphasis* here"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with emphasis underscore" {
    const lines = [_][]const u8{"snake_case identifier"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with backtick code span" {
    const lines = [_][]const u8{"uses `code` span"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with backslash escape" {
    const lines = [_][]const u8{"backslash\\escape"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with image bang" {
    const lines = [_][]const u8{"exclaim! bang"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with bracket open" {
    const lines = [_][]const u8{"bracket[open"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with bracket close" {
    const lines = [_][]const u8{"bracket]close"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with tilde strikethrough" {
    const lines = [_][]const u8{"strike ~through~ it"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with autolink angle bracket" {
    const lines = [_][]const u8{"angle < bracket"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects line with ampersand entity candidate" {
    const lines = [_][]const u8{"fish & chips"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects non-final line with trailing two spaces" {
    const lines = [_][]const u8{
        "first line  ",
        "second line",
    };
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects non-final line with more than two trailing spaces" {
    const lines = [_][]const u8{
        "first   ",
        "second",
    };
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial accepts final line with trailing two spaces" {
    const lines = [_][]const u8{
        "only line  ",
    };
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial accepts non-final line with a single trailing space" {
    const lines = [_][]const u8{
        "first line ",
        "second line",
    };
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial accepts line with single colon not forming scheme" {
    const lines = [_][]const u8{"It works: really it does"};
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial rejects bare http URL via scheme marker" {
    const lines = [_][]const u8{"visit http://example.com today"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects bare https URL via scheme marker" {
    const lines = [_][]const u8{"see https://example.com"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial rejects custom scheme like file URL" {
    const lines = [_][]const u8{"file:///etc/hosts opens locally"};
    try std.testing.expect(!isTrivial(&lines));
}

test "isTrivial handles empty lines inside a non-empty slice" {
    const lines = [_][]const u8{
        "real content",
        "",
        "more content",
    };
    try std.testing.expect(isTrivial(&lines));
}

test "isTrivial treats a single empty line as trivial" {
    const lines = [_][]const u8{""};
    try std.testing.expect(isTrivial(&lines));
}

test "endsWithHardBreakSpaces exact two trailing spaces" {
    try std.testing.expect(endsWithHardBreakSpaces("abc  "));
}

test "endsWithHardBreakSpaces three trailing spaces" {
    try std.testing.expect(endsWithHardBreakSpaces("abc   "));
}

test "endsWithHardBreakSpaces single trailing space" {
    try std.testing.expect(!endsWithHardBreakSpaces("abc "));
}

test "endsWithHardBreakSpaces no trailing space" {
    try std.testing.expect(!endsWithHardBreakSpaces("abc"));
}

test "endsWithHardBreakSpaces empty line" {
    try std.testing.expect(!endsWithHardBreakSpaces(""));
}

test "endsWithHardBreakSpaces line of two spaces only" {
    try std.testing.expect(endsWithHardBreakSpaces("  "));
}
