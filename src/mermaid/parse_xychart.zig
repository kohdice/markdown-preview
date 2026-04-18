const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    OutOfMemory,
};

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) ParseError!types.XyChart {
    var chart: types.XyChart = .{ .allocator = allocator };
    errdefer chart.deinit();

    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    var series_list: std.ArrayListUnmanaged(types.XySeries) = .empty;
    errdefer {
        for (series_list.items) |s| if (s.data.len > 0) allocator.free(s.data);
        series_list.deinit(allocator);
    }

    var header_seen = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const no_cr = std.mem.trimRight(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, no_cr, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (!header_seen) {
            try validateHeader(trimmed, &chart);
            header_seen = true;
            continue;
        }

        try parseDirective(allocator, &chart, &owned, &series_list, trimmed);
    }

    if (!header_seen) return error.InvalidMermaid;

    if (chart.x_axis.kind == .category and chart.x_axis.categories.len > 0) {
        const expected = chart.x_axis.categories.len;
        for (series_list.items) |s| {
            if (s.data.len != expected) return error.InvalidMermaid;
        }
    }

    chart.owned_strings = try owned.toOwnedSlice(allocator);
    chart.series = try series_list.toOwnedSlice(allocator);
    return chart;
}

fn validateHeader(line: []const u8, chart: *types.XyChart) ParseError!void {
    const keyword = "xychart";
    if (line.len < keyword.len) return error.InvalidMermaid;
    if (!std.ascii.eqlIgnoreCase(line[0..keyword.len], keyword)) return error.InvalidMermaid;
    const rest = line[keyword.len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return error.InvalidMermaid;

    const tail = std.mem.trim(u8, rest, " \t");
    if (tail.len == 0) return;
    if (std.ascii.eqlIgnoreCase(tail, "horizontal")) {
        chart.orientation = .horizontal;
        return;
    }
    if (std.ascii.eqlIgnoreCase(tail, "vertical")) {
        chart.orientation = .vertical;
        return;
    }
    return error.InvalidMermaid;
}

fn parseDirective(
    allocator: std.mem.Allocator,
    chart: *types.XyChart,
    owned: *std.ArrayListUnmanaged([]u8),
    series_list: *std.ArrayListUnmanaged(types.XySeries),
    line: []const u8,
) ParseError!void {
    if (takeKeyword(line, "title")) |rest| {
        const body = std.mem.trim(u8, rest, " \t");
        const dup = try parseTitleBody(allocator, body);
        try owned.append(allocator, dup);
        chart.title = dup;
        return;
    }
    if (takeKeyword(line, "x-axis")) |rest| {
        return parseAxisDirective(allocator, &chart.x_axis, owned, rest, true);
    }
    if (takeKeyword(line, "y-axis")) |rest| {
        return parseAxisDirective(allocator, &chart.y_axis, owned, rest, false);
    }
    if (takeKeyword(line, "bar")) |rest| {
        return parseSeriesDirective(allocator, series_list, rest, .bar);
    }
    if (takeKeyword(line, "line")) |rest| {
        return parseSeriesDirective(allocator, series_list, rest, .line);
    }
    return error.InvalidMermaid;
}

fn parseSeriesDirective(
    allocator: std.mem.Allocator,
    series_list: *std.ArrayListUnmanaged(types.XySeries),
    rest: []const u8,
    kind: types.XySeriesKind,
) ParseError!void {
    const body = std.mem.trim(u8, rest, " \t");
    const data = try parseNumberList(allocator, body);
    errdefer allocator.free(data);
    try series_list.append(allocator, .{ .kind = kind, .data = data });
}

fn parseNumberList(allocator: std.mem.Allocator, text: []const u8) ParseError![]f64 {
    if (text.len < 2 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidMermaid;
    const inner = text[1 .. text.len - 1];

    var items: std.ArrayListUnmanaged(f64) = .empty;
    errdefer items.deinit(allocator);

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;

        const start = i;
        while (i < inner.len and inner[i] != ',' and inner[i] != ' ' and inner[i] != '\t') : (i += 1) {}
        if (start == i) return error.InvalidMermaid;
        const tok = inner[start..i];
        const v = try parseNumber(tok);
        try items.append(allocator, v);

        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i < inner.len) {
            if (inner[i] != ',') return error.InvalidMermaid;
            i += 1;
        }
    }

    return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseAxisDirective(
    allocator: std.mem.Allocator,
    axis: *types.XyAxis,
    owned: *std.ArrayListUnmanaged([]u8),
    rest: []const u8,
    allow_categories: bool,
) ParseError!void {
    const body = std.mem.trim(u8, rest, " \t");
    if (body.len == 0) return error.InvalidMermaid;

    var title: ?[]const u8 = null;
    var cursor: []const u8 = body;

    if (body[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, body, 1, '"') orelse return error.InvalidMermaid;
        const dup = allocator.dupe(u8, body[1..end]) catch return error.OutOfMemory;
        try owned.append(allocator, dup);
        title = dup;
        cursor = std.mem.trim(u8, body[end + 1 ..], " \t");
    } else if (body[0] != '[' and !isNumericStart(body[0])) {
        var i: usize = 0;
        while (i < body.len and body[i] != ' ' and body[i] != '\t') : (i += 1) {}
        const dup = allocator.dupe(u8, body[0..i]) catch return error.OutOfMemory;
        try owned.append(allocator, dup);
        title = dup;
        cursor = std.mem.trim(u8, body[i..], " \t");
    }

    resetAxis(allocator, axis);
    axis.title = title;

    if (cursor.len == 0) return;

    if (cursor[0] == '[') {
        if (!allow_categories) return error.InvalidMermaid;
        const categories = try parseCategoryList(allocator, owned, cursor);
        axis.kind = .category;
        axis.categories = categories;
        return;
    }

    if (std.mem.indexOf(u8, cursor, "-->")) |arrow| {
        const min_str = std.mem.trim(u8, cursor[0..arrow], " \t");
        const max_str = std.mem.trim(u8, cursor[arrow + 3 ..], " \t");
        const min_v = try parseNumber(min_str);
        const max_v = try parseNumber(max_str);
        if (!(max_v > min_v)) return error.InvalidMermaid;
        axis.kind = .numeric;
        axis.numeric_min = min_v;
        axis.numeric_max = max_v;
        axis.has_explicit_range = true;
        return;
    }

    return error.InvalidMermaid;
}

fn resetAxis(allocator: std.mem.Allocator, axis: *types.XyAxis) void {
    if (axis.categories.len > 0) allocator.free(axis.categories);
    axis.* = .{};
}

fn parseNumber(text: []const u8) ParseError!f64 {
    return std.fmt.parseFloat(f64, text) catch error.InvalidMermaid;
}

fn parseCategoryList(
    allocator: std.mem.Allocator,
    owned: *std.ArrayListUnmanaged([]u8),
    text: []const u8,
) ParseError![][]const u8 {
    if (text.len < 2 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidMermaid;
    const inner = text[1 .. text.len - 1];

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer items.deinit(allocator);

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;

        var item: []u8 = undefined;
        if (inner[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < inner.len and inner[i] != '"') : (i += 1) {}
            if (i >= inner.len) return error.InvalidMermaid;
            item = allocator.dupe(u8, inner[start..i]) catch return error.OutOfMemory;
            i += 1;
        } else {
            const start = i;
            while (i < inner.len and inner[i] != ',' and inner[i] != ' ' and inner[i] != '\t') : (i += 1) {}
            if (start == i) return error.InvalidMermaid;
            item = allocator.dupe(u8, inner[start..i]) catch return error.OutOfMemory;
        }
        try owned.append(allocator, item);
        try items.append(allocator, item);

        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i < inner.len) {
            if (inner[i] != ',') return error.InvalidMermaid;
            i += 1;
        }
    }

    return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn isNumericStart(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.';
}

fn parseTitleBody(allocator: std.mem.Allocator, body: []const u8) ParseError![]u8 {
    if (body.len == 0) return error.InvalidMermaid;
    if (body[0] == '"') return parseQuotedString(allocator, body);
    for (body) |c| {
        if (c == ' ' or c == '\t') return error.InvalidMermaid;
    }
    return allocator.dupe(u8, body) catch return error.OutOfMemory;
}

fn takeKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (line.len <= keyword.len) return null;
    if (!std.mem.eql(u8, line[0..keyword.len], keyword)) return null;
    const next = line[keyword.len];
    if (next != ' ' and next != '\t') return null;
    return line[keyword.len..];
}

fn parseQuotedString(allocator: std.mem.Allocator, body: []const u8) ParseError![]u8 {
    if (body.len < 2 or body[0] != '"' or body[body.len - 1] != '"') return error.InvalidMermaid;
    const inner = body[1 .. body.len - 1];
    return allocator.dupe(u8, inner) catch return error.OutOfMemory;
}

test "parseSource rejects source without xychart header" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "flowchart TD\n  A --> B\n"),
    );
}

test "parseSource rejects legacy xychart-beta header" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "xychart-beta\n"),
    );
}

test "parseSource accepts bare xychart header with no body" {
    var chart = try parseSource(std.testing.allocator, "xychart\n");
    defer chart.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), chart.title);
    try std.testing.expectEqual(types.XyOrientation.vertical, chart.orientation);
    try std.testing.expectEqual(@as(usize, 0), chart.series.len);
    try std.testing.expect(!chart.x_axis.has_explicit_range);
    try std.testing.expect(!chart.y_axis.has_explicit_range);
}

test "parseSource parses title directive with quoted string" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\title "My Chart"
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("My Chart", chart.title.?);
}

test "parseSource parses title directive with single bareword" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\title Chart
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("Chart", chart.title.?);
}

test "parseSource rejects multi-word unquoted title" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\title Foo Bar
    ));
}

test "parseSource parses category x-axis with [a, b, c]" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
    );
    defer chart.deinit();
    try std.testing.expectEqual(types.XyAxisKind.category, chart.x_axis.kind);
    try std.testing.expectEqual(@as(usize, 3), chart.x_axis.categories.len);
    try std.testing.expectEqualStrings("a", chart.x_axis.categories[0]);
    try std.testing.expectEqualStrings("b", chart.x_axis.categories[1]);
    try std.testing.expectEqualStrings("c", chart.x_axis.categories[2]);
    try std.testing.expectEqual(@as(?[]const u8, null), chart.x_axis.title);
}

test "parseSource parses category x-axis with quoted entries containing spaces" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis "Months" ["Jan", "Feb Mar", "Apr"]
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("Months", chart.x_axis.title.?);
    try std.testing.expectEqual(types.XyAxisKind.category, chart.x_axis.kind);
    try std.testing.expectEqual(@as(usize, 3), chart.x_axis.categories.len);
    try std.testing.expectEqualStrings("Jan", chart.x_axis.categories[0]);
    try std.testing.expectEqualStrings("Feb Mar", chart.x_axis.categories[1]);
    try std.testing.expectEqualStrings("Apr", chart.x_axis.categories[2]);
}

test "parseSource parses numeric x-axis with min --> max" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis 0 --> 10
    );
    defer chart.deinit();
    try std.testing.expectEqual(types.XyAxisKind.numeric, chart.x_axis.kind);
    try std.testing.expect(chart.x_axis.has_explicit_range);
    try std.testing.expectEqual(@as(f64, 0), chart.x_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 10), chart.x_axis.numeric_max);
    try std.testing.expectEqual(@as(?[]const u8, null), chart.x_axis.title);
}

test "parseSource parses y-axis title-only form (has_explicit_range=false)" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis "Revenue"
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("Revenue", chart.y_axis.title.?);
    try std.testing.expect(!chart.y_axis.has_explicit_range);
}

test "parseSource parses y-axis with numeric range" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis "Revenue" 0 --> 100
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("Revenue", chart.y_axis.title.?);
    try std.testing.expectEqual(types.XyAxisKind.numeric, chart.y_axis.kind);
    try std.testing.expect(chart.y_axis.has_explicit_range);
    try std.testing.expectEqual(@as(f64, 0), chart.y_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 100), chart.y_axis.numeric_max);
}

test "parseSource parses single bar series with positive integers" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 1), chart.series.len);
    try std.testing.expectEqual(types.XySeriesKind.bar, chart.series[0].kind);
    try std.testing.expectEqual(@as(usize, 3), chart.series[0].data.len);
    try std.testing.expectEqual(@as(f64, 1), chart.series[0].data[0]);
    try std.testing.expectEqual(@as(f64, 2), chart.series[0].data[1]);
    try std.testing.expectEqual(@as(f64, 3), chart.series[0].data[2]);
}

test "parseSource parses line series with negative and fractional values" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\line [-1.5, 2.75, -0.25]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 1), chart.series.len);
    try std.testing.expectEqual(types.XySeriesKind.line, chart.series[0].kind);
    try std.testing.expectEqual(@as(f64, -1.5), chart.series[0].data[0]);
    try std.testing.expectEqual(@as(f64, 2.75), chart.series[0].data[1]);
    try std.testing.expectEqual(@as(f64, -0.25), chart.series[0].data[2]);
}

test "parseSource parses leading-dot fraction .98 and signed -.34" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\line [.98, -.34, +.5]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(f64, 0.98), chart.series[0].data[0]);
    try std.testing.expectEqual(@as(f64, -0.34), chart.series[0].data[1]);
    try std.testing.expectEqual(@as(f64, 0.5), chart.series[0].data[2]);
}

test "parseSource parses multiple bar and line series in source order" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
        \\line [4, 5, 6]
        \\bar [7, 8, 9]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 3), chart.series.len);
    try std.testing.expectEqual(types.XySeriesKind.bar, chart.series[0].kind);
    try std.testing.expectEqual(types.XySeriesKind.line, chart.series[1].kind);
    try std.testing.expectEqual(types.XySeriesKind.bar, chart.series[2].kind);
    try std.testing.expectEqual(@as(f64, 1), chart.series[0].data[0]);
    try std.testing.expectEqual(@as(f64, 4), chart.series[1].data[0]);
    try std.testing.expectEqual(@as(f64, 7), chart.series[2].data[0]);
}

test "parseSource treats later axis redefinition as last-wins" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\x-axis 0 --> 10
    );
    defer chart.deinit();
    try std.testing.expectEqual(types.XyAxisKind.numeric, chart.x_axis.kind);
    try std.testing.expect(chart.x_axis.has_explicit_range);
    try std.testing.expectEqual(@as(f64, 0), chart.x_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 10), chart.x_axis.numeric_max);
    try std.testing.expectEqual(@as(usize, 0), chart.x_axis.categories.len);
}

test "parseSource detects horizontal orientation in header" {
    var chart = try parseSource(std.testing.allocator, "xychart horizontal\n");
    defer chart.deinit();
    try std.testing.expectEqual(types.XyOrientation.horizontal, chart.orientation);
}

test "parseSource defaults orientation to vertical when unspecified" {
    var chart = try parseSource(std.testing.allocator, "xychart\n");
    defer chart.deinit();
    try std.testing.expectEqual(types.XyOrientation.vertical, chart.orientation);
}

test "parseSource rejects bar series shorter than category count" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [1, 2]
    ));
}

test "parseSource rejects bar series longer than category count" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
        \\bar [1, 2, 3]
    ));
}

test "parseSource rejects line series mismatched with category count" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
        \\line [1, 2, 3]
    ));
}

test "parseSource rejects when any series among many mismatches categories" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
        \\bar [1, 2]
        \\line [1, 2, 3]
    ));
}

test "parseSource accepts series length equal to category count" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [1, 2, 3]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 1), chart.series.len);
    try std.testing.expectEqual(@as(usize, 3), chart.series[0].data.len);
}

test "parseSource accepts mismatched series length for numeric x-axis" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis 0 --> 10
        \\bar [1, 2, 3, 4, 5]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 1), chart.series.len);
    try std.testing.expectEqual(@as(usize, 5), chart.series[0].data.len);
}

test "parseSource accepts any series length when x-axis is implicit" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 1), chart.series.len);
}

test "parseSource accepts categories without any series" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(usize, 0), chart.series.len);
    try std.testing.expectEqual(@as(usize, 2), chart.x_axis.categories.len);
}

test "parseSource rejects reversed y-axis range 100 --> 0" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\y-axis 100 --> 0
    ));
}

test "parseSource rejects degenerate y-axis range 50 --> 50" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\y-axis 50 --> 50
    ));
}

test "parseSource rejects reversed x-axis numeric range 10 --> -5" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\x-axis 10 --> -5
    ));
}

test "parseSource accepts ascending y-axis range 0 --> 100" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis 0 --> 100
    );
    defer chart.deinit();
    try std.testing.expect(chart.y_axis.has_explicit_range);
    try std.testing.expectEqual(@as(f64, 0), chart.y_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 100), chart.y_axis.numeric_max);
}

test "parseSource accepts y-axis range crossing zero -10 --> 10" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis -10 --> 10
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(f64, -10), chart.y_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 10), chart.y_axis.numeric_max);
}

test "parseSource accepts small positive y-axis range 0.1 --> 0.2" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis 0.1 --> 0.2
    );
    defer chart.deinit();
    try std.testing.expectEqual(@as(f64, 0.1), chart.y_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 0.2), chart.y_axis.numeric_max);
}

test "parseSource rejects y-axis bare category list" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\y-axis [a, b]
    ));
}

test "parseSource rejects y-axis title plus category list" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\xychart
        \\y-axis "Revenue" [a, b]
    ));
}

test "parseSource accepts y-axis title-only form" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis "Revenue"
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("Revenue", chart.y_axis.title.?);
    try std.testing.expect(!chart.y_axis.has_explicit_range);
}

test "parseSource accepts y-axis with title and numeric range" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\y-axis "Revenue" 0 --> 100
    );
    defer chart.deinit();
    try std.testing.expectEqualStrings("Revenue", chart.y_axis.title.?);
    try std.testing.expect(chart.y_axis.has_explicit_range);
    try std.testing.expectEqual(@as(f64, 0), chart.y_axis.numeric_min);
    try std.testing.expectEqual(@as(f64, 100), chart.y_axis.numeric_max);
}

test "parseSource still accepts x-axis category list after tightening y-axis" {
    var chart = try parseSource(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
        \\bar [1, 2]
    );
    defer chart.deinit();
    try std.testing.expectEqual(types.XyAxisKind.category, chart.x_axis.kind);
    try std.testing.expectEqual(@as(usize, 2), chart.x_axis.categories.len);
}
