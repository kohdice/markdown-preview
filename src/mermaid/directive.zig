const std = @import("std");

pub const Error = error{
    UnsupportedFeature,
    OutOfMemory,
};

pub fn stripInitDirectives(
    allocator: std.mem.Allocator,
    source: []const u8,
    unsafe_keys: []const []const u8,
) Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < source.len) {
        const line_start = cursor;
        const nl = std.mem.indexOfScalarPos(u8, source, cursor, '\n');
        const line_end = nl orelse source.len;

        var i = line_start;
        while (i < line_end and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}

        if (line_end - i >= 3 and source[i] == '%' and source[i + 1] == '%' and source[i + 2] == '{') {
            const body_start = i + 3;
            const end_rel = std.mem.indexOf(u8, source[body_start..], "}%%") orelse {
                try buf.appendSlice(allocator, source[line_start..]);
                return buf.toOwnedSlice(allocator);
            };
            const block_end = body_start + end_rel + 3;
            const body = source[body_start .. body_start + end_rel];
            for (unsafe_keys) |k| {
                if (std.mem.indexOf(u8, body, k) != null) return error.UnsupportedFeature;
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
    return buf.toOwnedSlice(allocator);
}

test "stripInitDirectives passes through source without directives" {
    const out = try stripInitDirectives(std.testing.allocator, "graph TD\n    A --> B\n", &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("graph TD\n    A --> B\n", out);
}

test "stripInitDirectives strips a leading single-line block" {
    const out = try stripInitDirectives(
        std.testing.allocator,
        "%%{init: { \"theme\": \"dark\" }}%%\ngraph TD\n",
        &.{},
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("graph TD\n", out);
}

test "stripInitDirectives strips a multi-line block" {
    const src =
        \\%%{init: {
        \\  "theme": "dark"
        \\}}%%
        \\graph TD
    ;
    const out = try stripInitDirectives(std.testing.allocator, src, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("graph TD", out);
}

test "stripInitDirectives keeps %%{...}%% embedded in labels" {
    const src = "sequenceDiagram\n    Alice->>Bob: %%{x}%%\n";
    const out = try stripInitDirectives(std.testing.allocator, src, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "stripInitDirectives rejects directive matching any unsafe key" {
    try std.testing.expectError(error.UnsupportedFeature, stripInitDirectives(
        std.testing.allocator,
        "%%{init: { \"gitGraph\": { \"mainBranchName\": \"trunk\" } }}%%\n",
        &.{"\"gitGraph\""},
    ));
}

test "stripInitDirectives ignores unsafe key when caller did not register it" {
    const out = try stripInitDirectives(
        std.testing.allocator,
        "%%{init: { \"flowchart\": { \"curve\": \"basis\" } }}%%\nsequenceDiagram\n",
        &.{"\"sequence\""},
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("sequenceDiagram\n", out);
}
