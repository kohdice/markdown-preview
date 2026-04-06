const std = @import("std");
const block = @import("block.zig");

pub const LinkDef = struct {
    url: []const u8,
    title: ?[]const u8 = null,
};

pub const LinkDefMap = std.StringHashMapUnmanaged(LinkDef);

pub const LinkDefinition = struct {
    label: []const u8,
    url: []const u8,
    title: ?[]const u8,
};

pub fn collectLinkDefinitions(allocator: std.mem.Allocator, input: []const u8) !LinkDefMap {
    var defs: LinkDefMap = .{};
    var line_start: usize = 0;
    var active_prepass_fence: ?block.Fence = null;

    while (line_start < input.len) {
        const line_end = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
        const has_newline = line_end < input.len;
        const line = std.mem.trimEnd(u8, input[line_start..line_end], "\r");

        if (active_prepass_fence) |fence| {
            if (block.isClosingFence(line, fence)) {
                active_prepass_fence = null;
            }
        } else if (block.parseFence(line)) |fence| {
            active_prepass_fence = fence;
        } else {
            if (parseLinkDefinition(line)) |def| {
                const lower = std.ascii.allocLowerString(allocator, def.label) catch null;
                if (lower) |key| {
                    const result = defs.getOrPut(allocator, key) catch {
                        allocator.free(key);
                        line_start = line_end + @intFromBool(has_newline);
                        continue;
                    };
                    if (result.found_existing) {
                        allocator.free(key);
                    } else {
                        result.value_ptr.* = .{ .url = def.url, .title = def.title };
                    }
                }
            }
        }

        line_start = line_end + @intFromBool(has_newline);
    }
    return defs;
}

pub fn parseLinkDefinition(line: []const u8) ?LinkDefinition {
    const indent = block.countIndentUpTo(line, block.max_block_indent);
    if (indent >= line.len or line[indent] != '[') return null;

    const close = std.mem.indexOfScalarPos(u8, line, indent + 1, ']') orelse return null;
    if (close + 1 >= line.len or line[close + 1] != ':') return null;

    const label = line[indent + 1 .. close];
    if (label.len == 0) return null;

    var pos = close + 2;
    while (pos < line.len and block.isHorizontalWhitespace(line[pos])) : (pos += 1) {}

    if (pos >= line.len) return null;

    var url_start = pos;
    var url_end = pos;
    if (line[pos] == '<') {
        url_start = pos + 1;
        url_end = std.mem.indexOfScalarPos(u8, line, url_start, '>') orelse return null;
        pos = url_end + 1;
    } else {
        while (url_end < line.len and !block.isHorizontalWhitespace(line[url_end])) : (url_end += 1) {}
        pos = url_end;
    }

    const url = line[url_start..url_end];
    if (url.len == 0) return null;

    while (pos < line.len and block.isHorizontalWhitespace(line[pos])) : (pos += 1) {}

    var title: ?[]const u8 = null;
    if (pos < line.len) {
        const quote = line[pos];
        if (quote == '"' or quote == '\'') {
            const title_start = pos + 1;
            const title_end = std.mem.indexOfScalarPos(u8, line, title_start, quote) orelse return null;
            title = line[title_start..title_end];
            pos = title_end + 1;
        } else {
            return null;
        }
    }

    const remaining = std.mem.trim(u8, line[pos..], block.horizontal_whitespace);
    if (remaining.len > 0) return null;

    return .{ .label = label, .url = url, .title = title };
}
