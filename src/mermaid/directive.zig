const std = @import("std");
const source_mod = @import("source.zig");

pub const Error = error{
    InvalidDirective,
    UnsupportedFeature,
    OutOfMemory,
};

pub fn stripInitDirectives(
    allocator: std.mem.Allocator,
    source: []const u8,
    unsafe_keys: []const []const u8,
) Error!source_mod.Source {
    const first = firstDirectiveStart(source) orelse return .{ .borrowed = source };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, source[0..first]);

    var cursor: usize = first;
    while (cursor < source.len) {
        const line_start = cursor;
        const nl = std.mem.findScalarPos(u8, source, cursor, '\n');
        const line_end = nl orelse source.len;

        var i = line_start;
        while (i < line_end and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}

        if (line_end - i >= 3 and source[i] == '%' and source[i + 1] == '%' and source[i + 2] == '{') {
            const body_start = i + 3;
            const end_rel = std.mem.find(u8, source[body_start..], "}%%") orelse return error.InvalidDirective;
            const block_end = body_start + end_rel + 3;
            const body = source[body_start .. body_start + end_rel];
            for (unsafe_keys) |k| {
                if (std.mem.find(u8, body, k) != null) return error.UnsupportedFeature;
            }

            var next = block_end;
            while (next < source.len and (source[next] == ' ' or source[next] == '\t' or source[next] == '\r')) : (next += 1) {}
            if (next < source.len and source[next] == '\n') next += 1;
            cursor = next;
            continue;
        }

        const line_inclusive_end = if (nl != null) line_end + 1 else line_end;
        try buf.appendSlice(allocator, source[line_start..line_inclusive_end]);
        cursor = line_inclusive_end;
    }
    return .{ .owned = try buf.toOwnedSlice(allocator) };
}

fn firstDirectiveStart(source: []const u8) ?usize {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const line_start = cursor;
        const nl = std.mem.findScalarPos(u8, source, cursor, '\n');
        const line_end = nl orelse source.len;

        var i = line_start;
        while (i < line_end and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}

        if (line_end - i >= 3 and source[i] == '%' and source[i + 1] == '%' and source[i + 2] == '{') {
            return line_start;
        }

        cursor = if (nl != null) line_end + 1 else line_end;
    }
    return null;
}

fn freeStripped(allocator: std.mem.Allocator, result: source_mod.Source) void {
    switch (result) {
        .borrowed => {},
        .owned => |b| allocator.free(b),
    }
}

test "stripInitDirectives returns borrowed for source without directives" {
    const src = "graph TD\n    A --> B\n";
    const result = try stripInitDirectives(std.testing.allocator, src, &.{});
    defer freeStripped(std.testing.allocator, result);
    try std.testing.expect(result == .borrowed);
    try std.testing.expectEqual(@as([*]const u8, src.ptr), result.borrowed.ptr);
    try std.testing.expectEqualStrings(src, result.bytes());
}

test "stripInitDirectives strips a leading single-line block" {
    const result = try stripInitDirectives(
        std.testing.allocator,
        "%%{init: { \"theme\": \"dark\" }}%%\ngraph TD\n",
        &.{},
    );
    defer freeStripped(std.testing.allocator, result);
    try std.testing.expect(result == .owned);
    try std.testing.expectEqualStrings("graph TD\n", result.bytes());
}

test "stripInitDirectives strips a multi-line block" {
    const src =
        \\%%{init: {
        \\  "theme": "dark"
        \\}}%%
        \\graph TD
    ;
    const result = try stripInitDirectives(std.testing.allocator, src, &.{});
    defer freeStripped(std.testing.allocator, result);
    try std.testing.expect(result == .owned);
    try std.testing.expectEqualStrings("graph TD", result.bytes());
}

test "stripInitDirectives keeps %%{...}%% embedded in labels as borrowed" {
    const src = "sequenceDiagram\n    Alice->>Bob: %%{x}%%\n";
    const result = try stripInitDirectives(std.testing.allocator, src, &.{});
    defer freeStripped(std.testing.allocator, result);
    try std.testing.expect(result == .borrowed);
    try std.testing.expectEqualStrings(src, result.bytes());
}

test "stripInitDirectives rejects directive matching any unsafe key" {
    try std.testing.expectError(error.UnsupportedFeature, stripInitDirectives(
        std.testing.allocator,
        "%%{init: { \"gitGraph\": { \"mainBranchName\": \"trunk\" } }}%%\n",
        &.{"\"gitGraph\""},
    ));
}

test "stripInitDirectives rejects unclosed directive" {
    try std.testing.expectError(error.InvalidDirective, stripInitDirectives(
        std.testing.allocator,
        "%%{init:\ngraph TD\n",
        &.{},
    ));
}

test "stripInitDirectives ignores unsafe key when caller did not register it" {
    const result = try stripInitDirectives(
        std.testing.allocator,
        "%%{init: { \"flowchart\": { \"curve\": \"basis\" } }}%%\nsequenceDiagram\n",
        &.{"\"sequence\""},
    );
    defer freeStripped(std.testing.allocator, result);
    try std.testing.expect(result == .owned);
    try std.testing.expectEqualStrings("sequenceDiagram\n", result.bytes());
}
