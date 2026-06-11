const std = @import("std");
const ast = @import("../ast.zig");
const parse_block = @import("block.zig");
const parse_link = @import("link.zig");
const text_mod = @import("../text.zig");

const DefMap = ast.LinkDefMap;

const strong_delim_len = 2;
const bold_italic_delim_len = 3;
const strikethrough_delim_len = 2;
const max_emphasis_delim_run: usize = bold_italic_delim_len;
const max_strikethrough_delim_run: usize = strikethrough_delim_len;
const escaped_pair_len: usize = 2;
const image_opener_text = "![";
const link_tail_open_len: usize = 2;
const ascii_control_max: u8 = 0x1f;
const ascii_delete: u8 = 0x7f;
const utf8_continuation_mask: u8 = 0xC0;
const utf8_continuation_tag: u8 = 0x80;

const scheme_separator: []const u8 = "://";
const http_scheme: []const u8 = "http://";
const https_scheme: []const u8 = "https://";

const min_hard_break_spaces: usize = 2;

pub const InlineBuilder = struct {
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    nodes: std.ArrayList(ast.InlineNode) = .empty,
    next: std.ArrayList(ast.InlineRef) = .empty,
    temp_prev: std.ArrayList(TokenRef) = .empty,
    temp_delimiters: std.ArrayList(Delimiter) = .empty,
    temp_brackets: std.ArrayList(Bracket) = .empty,
    temp_reference_scratch: std.ArrayList(u8) = .empty,
    temp_inline_link_scratch: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) InlineBuilder {
        return initWithScratchAllocator(allocator, allocator);
    }

    pub fn initWithScratchAllocator(
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
    ) InlineBuilder {
        return .{
            .allocator = allocator,
            .scratch_allocator = scratch_allocator,
        };
    }

    pub fn reserve(self: *InlineBuilder, capacity: usize) !void {
        if (capacity == 0) return;
        try self.nodes.ensureTotalCapacityPrecise(self.allocator, capacity);
        try self.next.ensureTotalCapacityPrecise(self.allocator, capacity);
    }

    pub fn deinitScratch(self: *InlineBuilder) void {
        self.temp_prev.deinit(self.scratch_allocator);
        self.temp_delimiters.deinit(self.scratch_allocator);
        self.temp_brackets.deinit(self.scratch_allocator);
        self.temp_reference_scratch.deinit(self.scratch_allocator);
        self.temp_inline_link_scratch.deinit(self.scratch_allocator);

        self.temp_prev = .empty;
        self.temp_delimiters = .empty;
        self.temp_brackets = .empty;
        self.temp_reference_scratch = .empty;
        self.temp_inline_link_scratch = .empty;
    }

    pub const Storage = struct {
        nodes: []ast.InlineNode,
        next: []ast.InlineRef,
    };

    pub fn finish(self: *InlineBuilder) Storage {
        return .{
            .nodes = self.nodes.items,
            .next = self.next.items,
        };
    }

    pub fn parseSlice(self: *InlineBuilder, content: []const u8, link_defs: *const DefMap) anyerror!ast.InlineRef {
        if (content.len == 0) return ast.no_inline;

        const lines = [_][]const u8{content};
        return self.parseLogical(&lines, link_defs);
    }

    pub fn parseLines(self: *InlineBuilder, lines: []const []const u8, link_defs: *const DefMap) anyerror!ast.InlineRef {
        if (lines.len == 0) return ast.no_inline;
        return self.parseLogical(lines, link_defs);
    }

    fn parseLogical(self: *InlineBuilder, lines: []const []const u8, link_defs: *const DefMap) anyerror!ast.InlineRef {
        const start_index = self.nodes.items.len;
        errdefer {
            self.nodes.shrinkRetainingCapacity(start_index);
            self.next.shrinkRetainingCapacity(start_index);
        }

        var parser = TempParser.init(self, lines, link_defs);
        defer parser.deinit();

        return try parser.parse();
    }
};

test "InlineBuilder keeps materialized inline payloads outside scratch allocator" {
    var storage_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage_arena.deinit();

    var builder = InlineBuilder.initWithScratchAllocator(
        storage_arena.allocator(),
        std.testing.allocator,
    );
    errdefer builder.deinitScratch();
    var link_defs: DefMap = .{};

    _ = try builder.parseSlice("[x](a\\*b)", &link_defs);
    const storage = builder.finish();
    builder.deinitScratch();

    var found_link = false;
    for (storage.nodes) |node| {
        if (node == .link) {
            found_link = true;
            try std.testing.expectEqualStrings("a*b", node.link.url);
        }
    }
    try std.testing.expect(found_link);
}

const InlineChain = struct {
    head: ast.InlineRef = ast.no_inline,
    tail: ast.InlineRef = ast.no_inline,
};

const TokenRef = ast.InlineRef;
const no_token: TokenRef = ast.no_inline;

fn hasToken(ref: TokenRef) bool {
    return ref != no_token;
}

const Delimiter = struct {
    node: TokenRef,
    ch: u8,
    remaining: u8,
    can_open: bool,
    can_close: bool,
    active: bool = true,
};

const OpenerBottoms = struct {
    star: [max_emphasis_delim_run]usize = [_]usize{0} ** max_emphasis_delim_run,
    underscore: [max_emphasis_delim_run]usize = [_]usize{0} ** max_emphasis_delim_run,
    tilde: usize = 0,

    fn ptr(self: *OpenerBottoms, ch: u8, remaining: u8) *usize {
        return switch (ch) {
            '*' => &self.star[@as(usize, remaining) % max_emphasis_delim_run],
            '_' => &self.underscore[@as(usize, remaining) % max_emphasis_delim_run],
            '~' => &self.tilde,
            else => unreachable,
        };
    }

    fn reset(self: *OpenerBottoms, ch: u8) void {
        switch (ch) {
            '*' => self.star = [_]usize{0} ** max_emphasis_delim_run,
            '_' => self.underscore = [_]usize{0} ** max_emphasis_delim_run,
            '~' => self.tilde = 0,
            else => unreachable,
        }
    }
};

const Bracket = struct {
    node: TokenRef,
    line_index: usize,
    content_start: usize,
    is_image: bool,
    active: bool = true,
};

const CodeSpanMatch = struct {
    slice: []const u8,
    end_line: usize,
    end_col: usize,
};

const LinkTail = struct {
    url: []const u8,
    title: ?[]const u8,
    end_line: usize,
    end_col: usize,
};

const BracketResolution = struct {
    end_line: usize,
    end_col: usize,
};

const DelimiterClass = struct {
    can_open: bool,
    can_close: bool,
};

const TempParser = struct {
    builder: *InlineBuilder,
    lines: []const []const u8,
    link_defs: *const DefMap,
    start_index: usize,
    prev: std.ArrayList(TokenRef),
    delimiters: std.ArrayList(Delimiter),
    brackets: std.ArrayList(Bracket),
    reference_label_scratch: std.ArrayList(u8),
    inline_link_scratch: std.ArrayList(u8),
    opener_bottoms: OpenerBottoms = .{},
    chain: InlineChain = .{},

    fn init(
        builder: *InlineBuilder,
        lines: []const []const u8,
        link_defs: *const DefMap,
    ) TempParser {
        var result: TempParser = .{
            .builder = builder,
            .lines = lines,
            .link_defs = link_defs,
            .start_index = builder.nodes.items.len,
            .prev = builder.temp_prev,
            .delimiters = builder.temp_delimiters,
            .brackets = builder.temp_brackets,
            .reference_label_scratch = builder.temp_reference_scratch,
            .inline_link_scratch = builder.temp_inline_link_scratch,
        };
        result.prev.clearRetainingCapacity();
        result.delimiters.clearRetainingCapacity();
        result.brackets.clearRetainingCapacity();
        result.reference_label_scratch.clearRetainingCapacity();
        result.inline_link_scratch.clearRetainingCapacity();
        return result;
    }

    fn deinit(self: *TempParser) void {
        self.builder.temp_prev = self.prev;
        self.builder.temp_delimiters = self.delimiters;
        self.builder.temp_brackets = self.brackets;
        self.builder.temp_reference_scratch = self.reference_label_scratch;
        self.builder.temp_inline_link_scratch = self.inline_link_scratch;
    }

    fn parse(self: *TempParser) !TokenRef {
        var line_index: usize = 0;
        var col: usize = 0;
        var plain_start: usize = 0;

        while (line_index < self.lines.len) {
            const line = self.lines[line_index];

            if (col >= line.len) {
                if (line_index + 1 < self.lines.len) {
                    const tail = line[plain_start..];
                    const trimmed_end = trimTrailingBreakChars(tail);
                    try self.appendText(tail[0..trimmed_end]);
                    _ = try self.appendNode(if (isHardBreak(tail))
                        .{ .hard_break = {} }
                    else
                        .{ .soft_break = {} });
                    line_index += 1;
                    col = 0;
                    plain_start = 0;
                    continue;
                }

                try self.appendText(line[plain_start..]);
                break;
            }

            switch (line[col]) {
                '\\' => {
                    if (col + 1 < line.len and isEscapable(line[col + 1])) {
                        try self.appendText(line[plain_start..col]);
                        try self.appendText(line[col + 1 .. col + escaped_pair_len]);
                        col += escaped_pair_len;
                        plain_start = col;
                        continue;
                    }
                    col += 1;
                },
                '`' => {
                    if (try self.scanCodeSpan(line_index, col)) |code| {
                        try self.appendText(line[plain_start..col]);
                        _ = try self.appendNode(.{ .code_span = code.slice });
                        line_index = code.end_line;
                        col = code.end_col;
                        plain_start = col;
                        continue;
                    }
                    col += 1;
                },
                '!' => {
                    if (col + 1 < line.len and line[col + 1] == '[') {
                        try self.appendText(line[plain_start..col]);
                        const ref = try self.appendNode(.{ .text = line[col .. col + image_opener_text.len] });
                        try self.brackets.append(self.builder.scratch_allocator, .{
                            .node = ref,
                            .line_index = line_index,
                            .content_start = col + image_opener_text.len,
                            .is_image = true,
                        });
                        col += image_opener_text.len;
                        plain_start = col;
                        continue;
                    }
                    col += 1;
                },
                '[' => {
                    try self.appendText(line[plain_start..col]);
                    const ref = try self.appendNode(.{ .text = line[col .. col + 1] });
                    try self.brackets.append(self.builder.scratch_allocator, .{
                        .node = ref,
                        .line_index = line_index,
                        .content_start = col + 1,
                        .is_image = false,
                    });
                    col += 1;
                    plain_start = col;
                },
                ']' => {
                    try self.appendText(line[plain_start..col]);
                    if (try self.tryResolveBracket(line_index, col)) |resolved| {
                        line_index = resolved.end_line;
                        col = resolved.end_col;
                        plain_start = col;
                        continue;
                    }

                    if (self.findActiveBracket()) |bracket_index| {
                        self.brackets.items[bracket_index].active = false;
                    }

                    try self.appendText(line[col .. col + 1]);
                    col += 1;
                    plain_start = col;
                },
                '*', '_' => {
                    const run_len = countRun(line, col, line[col]);
                    if (run_len > 0 and run_len <= max_emphasis_delim_run) {
                        const class = classifyEmphasisDelimiter(self.lines, line_index, col, run_len, line[col]);
                        if (class.can_open or class.can_close) {
                            try self.appendText(line[plain_start..col]);
                            const ref = try self.appendNode(.{ .text = line[col .. col + run_len] });
                            try self.delimiters.append(self.builder.scratch_allocator, .{
                                .node = ref,
                                .ch = line[col],
                                .remaining = @intCast(run_len),
                                .can_open = class.can_open,
                                .can_close = class.can_close,
                            });
                            if (class.can_close) {
                                try self.resolveDelimiter(self.delimiters.items.len - 1);
                            }
                            col += run_len;
                            plain_start = col;
                            continue;
                        }
                    }
                    col += run_len;
                },
                '~' => {
                    const run_len = countRun(line, col, '~');
                    if (run_len > 0 and run_len <= max_strikethrough_delim_run) {
                        const class = classifyStrikethroughDelimiter(self.lines, line_index, col, run_len);
                        if (class.can_open or class.can_close) {
                            try self.appendText(line[plain_start..col]);
                            const ref = try self.appendNode(.{ .text = line[col .. col + run_len] });
                            try self.delimiters.append(self.builder.scratch_allocator, .{
                                .node = ref,
                                .ch = '~',
                                .remaining = @intCast(run_len),
                                .can_open = class.can_open,
                                .can_close = class.can_close,
                            });
                            if (class.can_close) {
                                try self.resolveDelimiter(self.delimiters.items.len - 1);
                            }
                            col += run_len;
                            plain_start = col;
                            continue;
                        }
                    }
                    col += run_len;
                },
                '<' => {
                    if (tryParseAutolink(line, col)) |autolink| {
                        try self.appendText(line[plain_start..col]);
                        _ = try self.appendNode(.{ .autolink = autolink.url });
                        col = autolink.end;
                        plain_start = col;
                        continue;
                    }
                    col += 1;
                },
                'h' => {
                    if (tryParseBareUrl(line, col)) |bare| {
                        try self.appendText(line[plain_start..col]);
                        _ = try self.appendNode(.{ .autolink = line[col..bare.end] });
                        col = bare.end;
                        plain_start = col;
                        continue;
                    }
                    col += 1;
                },
                else => {
                    col += 1;
                },
            }
        }

        return self.chain.head;
    }

    fn appendText(self: *TempParser, content: []const u8) !void {
        if (content.len == 0) return;
        _ = try self.appendNode(.{ .text = content });
    }

    fn appendNode(self: *TempParser, node: ast.InlineNode) !TokenRef {
        const ref = try self.allocNode(node);
        self.appendRef(ref);
        return ref;
    }

    fn allocNode(self: *TempParser, node: ast.InlineNode) !TokenRef {
        const ref = std.math.cast(TokenRef, self.builder.nodes.items.len) orelse return error.Overflow;
        try self.builder.nodes.append(self.builder.allocator, node);
        try self.builder.next.append(self.builder.allocator, no_token);
        try self.prev.append(self.builder.scratch_allocator, no_token);
        return ref;
    }

    fn appendRef(self: *TempParser, ref: TokenRef) void {
        if (!hasToken(self.chain.head)) {
            self.chain.head = ref;
            self.chain.tail = ref;
            return;
        }

        const tail_index = tokenIndex(self.chain.tail);
        self.builder.next.items[tail_index] = ref;
        self.setPrev(ref, self.chain.tail);
        self.chain.tail = ref;
    }

    fn scanCodeSpan(self: *TempParser, start_line: usize, start_col: usize) !?CodeSpanMatch {
        const opener_line = self.lines[start_line];
        const opener_len = countRun(opener_line, start_col, '`');
        if (opener_len == 0) return null;

        var line_index = start_line;
        var col = start_col + opener_len;

        while (line_index < self.lines.len) {
            const line = self.lines[line_index];
            while (col < line.len) {
                if (line[col] == '`') {
                    const close_len = countRun(line, col, '`');
                    if (close_len == opener_len) {
                        return .{
                            .slice = try self.captureRange(start_line, start_col, line_index, col + close_len),
                            .end_line = line_index,
                            .end_col = col + close_len,
                        };
                    }
                    col += close_len;
                } else {
                    col += 1;
                }
            }

            line_index += 1;
            col = 0;
        }

        return null;
    }

    fn tryResolveBracket(self: *TempParser, line_index: usize, close_col: usize) !?BracketResolution {
        const opener_index = self.findActiveBracket() orelse return null;
        const opener = self.brackets.items[opener_index];
        const link_tail = try self.parseInlineLinkTail(line_index, close_col) orelse try self.parseReferenceLinkTail(opener, line_index, close_col) orelse return null;

        const opener_node = opener.node;
        const child_head = self.builder.next.items[tokenIndex(opener_node)];
        const child_tail = self.chain.tail;

        if (hasToken(child_head)) {
            self.setPrev(child_head, no_token);
            self.builder.next.items[tokenIndex(child_tail)] = no_token;
        }

        self.builder.next.items[tokenIndex(opener_node)] = no_token;
        self.chain.tail = opener_node;
        self.brackets.items[opener_index].active = false;

        self.builder.nodes.items[tokenIndex(opener_node)] = if (opener.is_image)
            .{ .image = .{
                .url = link_tail.url,
                .title = link_tail.title,
                .children = child_head,
            } }
        else
            .{ .link = .{
                .url = link_tail.url,
                .title = link_tail.title,
                .children = child_head,
            } };

        if (!opener.is_image) {
            for (self.brackets.items[0..opener_index]) |*bracket| {
                if (!bracket.is_image) bracket.active = false;
            }
        }

        return .{
            .end_line = link_tail.end_line,
            .end_col = link_tail.end_col,
        };
    }

    fn parseInlineLinkTail(self: *TempParser, start_line: usize, close_col: usize) !?LinkTail {
        const line = self.lines[start_line];
        if (close_col + 1 >= line.len or line[close_col + 1] != '(') return null;

        const tail_start = close_col + link_tail_open_len;
        switch (try parse_link.parseInlineTargetBorrowing(self.builder.allocator, line[tail_start..])) {
            .match => |target| return .{
                .url = target.url,
                .title = target.title,
                .end_line = start_line,
                .end_col = tail_start + target.end,
            },
            .invalid => return null,
            .incomplete => {},
        }

        self.inline_link_scratch.clearRetainingCapacity();

        var line_index = start_line;
        var line_start_col = tail_start;
        while (line_index < self.lines.len) {
            const current_line = self.lines[line_index];
            if (self.inline_link_scratch.items.len > 0) {
                try self.inline_link_scratch.append(self.builder.scratch_allocator, '\n');
            }
            try self.inline_link_scratch.appendSlice(
                self.builder.scratch_allocator,
                current_line[line_start_col..],
            );

            switch (try parse_link.parseInlineTarget(self.builder.allocator, self.inline_link_scratch.items)) {
                .match => |target| {
                    const end_loc = self.inlineLinkOffsetToLocation(
                        start_line,
                        close_col + link_tail_open_len,
                        target.end,
                    );
                    return .{
                        .url = target.url,
                        .title = target.title,
                        .end_line = end_loc.line_index,
                        .end_col = end_loc.col,
                    };
                },
                .invalid => return null,
                .incomplete => {},
            }

            line_index += 1;
            line_start_col = 0;
        }

        return null;
    }

    const LineLocation = struct {
        line_index: usize,
        col: usize,
    };

    fn inlineLinkOffsetToLocation(
        self: *TempParser,
        start_line: usize,
        start_col: usize,
        offset: usize,
    ) LineLocation {
        var remaining = offset;
        var line_index = start_line;
        var col = start_col;

        while (line_index < self.lines.len) {
            const line = self.lines[line_index];
            const line_remaining = line.len - col;
            if (remaining <= line_remaining) {
                return .{
                    .line_index = line_index,
                    .col = col + remaining,
                };
            }

            remaining -= line_remaining;
            if (line_index + 1 >= self.lines.len or remaining == 0) {
                return .{
                    .line_index = line_index,
                    .col = line.len,
                };
            }

            remaining -= 1;
            line_index += 1;
            col = 0;
        }

        unreachable;
    }

    fn parseReferenceLinkTail(
        self: *TempParser,
        opener: Bracket,
        line_index: usize,
        close_col: usize,
    ) !?LinkTail {
        if (self.link_defs.count() == 0) return null;

        const line = self.lines[line_index];
        if (close_col + 1 < line.len and line[close_col + 1] == '[') {
            const ref_start = close_col + link_tail_open_len;
            const ref_end = parse_link.findReferenceLabelEnd(line, ref_start) orelse return null;
            const label = if (ref_end > ref_start)
                line[ref_start..ref_end]
            else
                try self.captureRangeScratch(opener.line_index, opener.content_start, line_index, close_col);

            if (try lookupReferenceDefinition(
                self.builder.scratch_allocator,
                self.link_defs,
                &self.reference_label_scratch,
                label,
            )) |def| {
                return .{
                    .url = def.url,
                    .title = def.title,
                    .end_line = line_index,
                    .end_col = ref_end + 1,
                };
            }
            return null;
        }

        if (close_col + 1 < line.len and (line[close_col + 1] == '(' or line[close_col + 1] == '['))
            return null;

        const label = try self.captureRangeScratch(opener.line_index, opener.content_start, line_index, close_col);
        if (try lookupReferenceDefinition(
            self.builder.scratch_allocator,
            self.link_defs,
            &self.reference_label_scratch,
            label,
        )) |def| {
            return .{
                .url = def.url,
                .title = def.title,
                .end_line = line_index,
                .end_col = close_col + 1,
            };
        }

        return null;
    }

    fn resolveDelimiter(self: *TempParser, closer_index: usize) !void {
        while (true) {
            if (closer_index >= self.delimiters.items.len) break;
            const closer = self.delimiters.items[closer_index];
            if (!closer.active or !closer.can_close or closer.remaining == 0) break;

            const opener_index = self.findMatchingOpener(closer_index) orelse break;
            if (!try self.wrapDelimiter(opener_index, closer_index)) break;
        }
    }

    fn findMatchingOpener(self: *TempParser, closer_index: usize) ?usize {
        const closer = self.delimiters.items[closer_index];
        const bottom = self.opener_bottoms.ptr(closer.ch, closer.remaining);
        var index = closer_index;
        while (index > bottom.*) {
            index -= 1;
            const opener = self.delimiters.items[index];
            if (!opener.active or !opener.can_open) continue;
            if (opener.ch != closer.ch) continue;

            if ((closer.ch == '*' or closer.ch == '_') and violatesMultipleOfThree(opener.remaining, closer.remaining))
                continue;

            return index;
        }
        bottom.* = closer_index;
        return null;
    }

    fn wrapDelimiter(self: *TempParser, opener_index: usize, closer_index: usize) !bool {
        const opener = self.delimiters.items[opener_index];
        const closer = self.delimiters.items[closer_index];
        const use_len = chooseDelimiterUse(opener.remaining, closer.remaining, opener.ch);
        const opener_left = opener.remaining - use_len;
        const closer_left = closer.remaining - use_len;
        const opener_node = opener.node;
        const closer_node = closer.node;
        const child_head = self.builder.next.items[tokenIndex(opener_node)];

        if (!hasToken(child_head) or child_head == closer_node) return false;

        const child_tail = self.prevOf(closer_node);
        if (!hasToken(child_tail) or child_tail == opener_node) return false;

        self.setPrev(child_head, no_token);
        self.builder.next.items[tokenIndex(child_tail)] = no_token;

        const container_children = child_head;
        const container_node: ast.InlineNode = switch (opener.ch) {
            '~' => .{ .strikethrough = container_children },
            else => switch (use_len) {
                bold_italic_delim_len => .{ .bold_italic = container_children },
                strong_delim_len => .{ .strong = container_children },
                else => .{ .emphasis = container_children },
            },
        };

        var container_ref = opener_node;
        if (opener_left == 0) {
            self.builder.nodes.items[tokenIndex(opener_node)] = container_node;
            self.delimiters.items[opener_index].active = false;
            self.delimiters.items[opener_index].remaining = 0;
        } else {
            const opener_text = self.textSlice(opener_node);
            self.builder.nodes.items[tokenIndex(opener_node)] = .{ .text = opener_text[0..opener_left] };
            self.delimiters.items[opener_index].remaining = opener_left;
            container_ref = try self.allocNode(container_node);
            self.builder.next.items[tokenIndex(opener_node)] = container_ref;
            self.setPrev(container_ref, opener_node);
        }

        if (closer_left == 0) {
            self.builder.next.items[tokenIndex(container_ref)] = no_token;
            self.delimiters.items[closer_index].active = false;
            self.delimiters.items[closer_index].remaining = 0;
            self.chain.tail = container_ref;
        } else {
            const closer_text = self.textSlice(closer_node);
            self.builder.nodes.items[tokenIndex(closer_node)] = .{ .text = closer_text[closer_text.len - closer_left ..] };
            self.delimiters.items[closer_index].remaining = closer_left;
            self.builder.next.items[tokenIndex(container_ref)] = closer_node;
            self.setPrev(closer_node, container_ref);
            self.chain.tail = closer_node;
        }

        self.opener_bottoms.reset(opener.ch);
        return true;
    }

    fn findActiveBracket(self: *TempParser) ?usize {
        var index = self.brackets.items.len;
        while (index > 0) {
            index -= 1;
            if (self.brackets.items[index].active) return index;
        }
        return null;
    }

    fn textSlice(self: *TempParser, ref: TokenRef) []const u8 {
        return self.builder.nodes.items[tokenIndex(ref)].text;
    }

    fn captureRange(
        self: *TempParser,
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    ) ![]const u8 {
        return self.captureRangeWithAllocator(self.builder.allocator, start_line, start_col, end_line, end_col);
    }

    fn captureRangeScratch(
        self: *TempParser,
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    ) ![]const u8 {
        return self.captureRangeWithAllocator(self.builder.scratch_allocator, start_line, start_col, end_line, end_col);
    }

    fn captureRangeWithAllocator(
        self: *TempParser,
        allocator: std.mem.Allocator,
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    ) ![]const u8 {
        if (start_line == end_line) {
            return self.lines[start_line][start_col..end_col];
        }

        var total_len: usize = 0;
        var line_index = start_line;
        while (line_index <= end_line) : (line_index += 1) {
            const line = self.lines[line_index];
            const chunk = if (line_index == start_line)
                line[start_col..]
            else if (line_index == end_line)
                line[0..end_col]
            else
                line;
            total_len += chunk.len;
            if (line_index < end_line) total_len += 1;
        }

        const buffer = try allocator.alloc(u8, total_len);
        var out: usize = 0;
        line_index = start_line;
        while (line_index <= end_line) : (line_index += 1) {
            const line = self.lines[line_index];
            const chunk = if (line_index == start_line)
                line[start_col..]
            else if (line_index == end_line)
                line[0..end_col]
            else
                line;
            @memcpy(buffer[out .. out + chunk.len], chunk);
            out += chunk.len;
            if (line_index < end_line) {
                buffer[out] = '\n';
                out += 1;
            }
        }
        return buffer;
    }

    fn prevOf(self: *TempParser, ref: TokenRef) TokenRef {
        return self.prev.items[self.localIndex(ref)];
    }

    fn setPrev(self: *TempParser, ref: TokenRef, value: TokenRef) void {
        self.prev.items[self.localIndex(ref)] = value;
    }

    fn localIndex(self: *TempParser, ref: TokenRef) usize {
        return tokenIndex(ref) - self.start_index;
    }
};

fn tokenIndex(ref: TokenRef) usize {
    return @intCast(ref);
}

fn countRun(line: []const u8, start: usize, ch: u8) usize {
    var len: usize = 0;
    while (start + len < line.len and line[start + len] == ch) : (len += 1) {}
    return len;
}

fn prevCodepointAt(lines: []const []const u8, line_index: usize, col: usize) ?u21 {
    if (col > 0) return prevCodepoint(lines[line_index], col);
    if (line_index > 0) return '\n';
    return null;
}

fn nextCodepointAt(lines: []const []const u8, line_index: usize, col: usize) ?u21 {
    const line = lines[line_index];
    if (col < line.len) return nextCodepoint(line, col);
    if (line_index + 1 < lines.len) return '\n';
    return null;
}

fn classifyEmphasisDelimiter(
    lines: []const []const u8,
    line_index: usize,
    start_col: usize,
    run_len: usize,
    ch: u8,
) DelimiterClass {
    const before = cpClass(prevCodepointAt(lines, line_index, start_col));
    const after = cpClass(nextCodepointAt(lines, line_index, start_col + run_len));
    const flank = checkFlanking(before, after);

    var can_open = flank.left;
    var can_close = flank.right;
    if (ch == '_') {
        can_open = can_open and (!flank.right or before == .punctuation);
        can_close = can_close and (!flank.left or after == .punctuation);
    }

    return .{
        .can_open = can_open,
        .can_close = can_close,
    };
}

fn classifyStrikethroughDelimiter(
    lines: []const []const u8,
    line_index: usize,
    start_col: usize,
    run_len: usize,
) DelimiterClass {
    _ = run_len;
    const before = cpClass(prevCodepointAt(lines, line_index, start_col));
    const after = cpClass(nextCodepointAt(lines, line_index, start_col + 1));
    return .{
        .can_open = after != .whitespace,
        .can_close = before != .whitespace,
    };
}

fn chooseDelimiterUse(opener_len: u8, closer_len: u8, ch: u8) u8 {
    if (ch == '~') {
        return if (opener_len >= strikethrough_delim_len and closer_len >= strikethrough_delim_len)
            strikethrough_delim_len
        else
            1;
    }
    if (opener_len >= bold_italic_delim_len and closer_len >= bold_italic_delim_len) return bold_italic_delim_len;
    if (opener_len >= strong_delim_len and closer_len >= strong_delim_len) return strong_delim_len;
    return 1;
}

fn violatesMultipleOfThree(opener_len: u8, closer_len: u8) bool {
    const sum: u8 = opener_len + closer_len;
    return sum % max_emphasis_delim_run == 0 and
        (opener_len % max_emphasis_delim_run != 0 or closer_len % max_emphasis_delim_run != 0);
}

fn lookupReferenceDefinition(
    allocator: std.mem.Allocator,
    link_defs: *const DefMap,
    scratch: *std.ArrayList(u8),
    label: []const u8,
) !?ast.LinkDef {
    if (!parse_link.referenceLabelLengthFits(label)) return null;
    const normalized = try parse_link.normalizeReferenceLabelInto(scratch, allocator, label);
    if (normalized.len == 0) return null;
    return link_defs.get(normalized);
}

fn isHardBreak(line: []const u8) bool {
    if (line.len > 0 and line[line.len - 1] == '\\') return true;

    var trailing_spaces: usize = 0;
    var pos = line.len;
    while (pos > 0 and line[pos - 1] == ' ') {
        trailing_spaces += 1;
        pos -= 1;
    }
    return trailing_spaces >= min_hard_break_spaces;
}

fn trimTrailingBreakChars(line: []const u8) usize {
    if (line.len > 0 and line[line.len - 1] == '\\')
        return line.len - 1;

    var end = line.len;
    while (end > 0 and line[end - 1] == ' ')
        end -= 1;
    return end;
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    };
}

const CharClass = enum { whitespace, punctuation, other };

fn prevCodepoint(text: []const u8, pos: usize) ?u21 {
    if (pos == 0) return null;
    var start = pos - 1;
    while (start > 0 and text[start] & utf8_continuation_mask == utf8_continuation_tag) : (start -= 1) {}
    if (text[start] & utf8_continuation_mask == utf8_continuation_tag) return null;
    const step = text_mod.nextCodepoint(text, start) orelse return null;
    if (start + step.len != pos) return null;
    return step.cp;
}

fn nextCodepoint(text: []const u8, pos: usize) ?u21 {
    const step = text_mod.nextCodepoint(text, pos) orelse return null;
    return step.cp;
}

fn cpClass(cp: ?u21) CharClass {
    // CommonMark delimiter processing needs Unicode whitespace and punctuation
    // buckets, but compact range checks avoid a runtime lookup table.
    const c = cp orelse return .whitespace;
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c') return .whitespace;
    if (c == 0x00A0) return .whitespace;
    if (c >= 0x2000 and c <= 0x200A) return .whitespace;
    if (c == 0x202F or c == 0x205F or c == 0x3000) return .whitespace;
    if (c >= 0x21 and c <= 0x2F) return .punctuation;
    if (c >= 0x3A and c <= 0x40) return .punctuation;
    if (c >= 0x5B and c <= 0x60) return .punctuation;
    if (c >= 0x7B and c <= 0x7E) return .punctuation;
    if (c >= 0x00A1 and c <= 0x00BF) return .punctuation;
    if (c == 0x00D7 or c == 0x00F7) return .punctuation;
    if (c >= 0x2010 and c <= 0x2027) return .punctuation;
    if (c >= 0x2030 and c <= 0x205E) return .punctuation;
    if (c >= 0x20A0 and c <= 0x20CF) return .punctuation;
    if (c >= 0x2100 and c <= 0x214F) return .punctuation;
    if (c >= 0x2190 and c <= 0x21FF) return .punctuation;
    if (c >= 0x2200 and c <= 0x22FF) return .punctuation;
    if (c >= 0x2300 and c <= 0x23FF) return .punctuation;
    if (c >= 0x2500 and c <= 0x25FF) return .punctuation;
    if (c >= 0x2600 and c <= 0x26FF) return .punctuation;
    if (c >= 0x2E00 and c <= 0x2E4F) return .punctuation;
    if (c >= 0x3001 and c <= 0x303F) return .punctuation;
    if (c >= 0xFF01 and c <= 0xFF0F) return .punctuation;
    if (c >= 0xFF1A and c <= 0xFF20) return .punctuation;
    if (c >= 0xFF3B and c <= 0xFF3F) return .punctuation;
    if (c >= 0xFF5B and c <= 0xFF65) return .punctuation;
    return .other;
}

fn checkFlanking(before: CharClass, after: CharClass) struct { left: bool, right: bool } {
    const left = after != .whitespace and
        (after != .punctuation or before == .whitespace or before == .punctuation);

    const right = before != .whitespace and
        (before != .punctuation or after == .whitespace or after == .punctuation);

    return .{ .left = left, .right = right };
}

const AutolinkResult = struct {
    url: []const u8,
    end: usize,
};

fn tryParseAutolink(text: []const u8, start: usize) ?AutolinkResult {
    if (start >= text.len or text[start] != '<') return null;

    var pos = start + 1;
    var scheme_end: usize = 0;
    while (pos < text.len) {
        switch (text[pos]) {
            '>' => {
                if (scheme_end == 0) return null;
                const scheme = text[start + 1 .. scheme_end - scheme_separator.len];
                if (scheme.len == 0) return null;
                if (!std.ascii.isAlphabetic(scheme[0])) return null;
                return .{
                    .url = text[start + 1 .. pos],
                    .end = pos + 1,
                };
            },
            ' ', '\t', '\n', '<' => return null,
            ':' => {
                if (scheme_end == 0 and std.mem.startsWith(u8, text[pos..], scheme_separator)) {
                    scheme_end = pos + scheme_separator.len;
                }
                pos += 1;
            },
            else => {
                pos += 1;
            },
        }
    }
    return null;
}

const BareUrlResult = struct {
    end: usize,
};

fn tryParseBareUrl(text: []const u8, start: usize) ?BareUrlResult {
    const rest = text[start..];
    const prefix_len: usize = if (std.mem.startsWith(u8, rest, https_scheme))
        https_scheme.len
    else if (std.mem.startsWith(u8, rest, http_scheme))
        http_scheme.len
    else
        return null;

    if (start > 0) {
        const prev = text[start - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '.' or prev == '/' or prev == ':')
            return null;
    }

    if (start + prefix_len >= text.len) return null;

    var pos = start + prefix_len;
    var open_count: usize = 0;
    var close_count: usize = 0;
    while (pos < text.len) {
        switch (text[pos]) {
            ' ', '<', '>', 0...ascii_control_max, ascii_delete => break,
            '(' => {
                open_count += 1;
                pos += 1;
            },
            ')' => {
                close_count += 1;
                pos += 1;
            },
            else => pos += 1,
        }
    }

    while (pos > start + prefix_len) {
        switch (text[pos - 1]) {
            '.', ',', ':', '!', '?', '*', '_', '~', '\'', '"' => pos -= 1,
            ')' => {
                if (close_count > open_count) {
                    pos -= 1;
                    close_count -= 1;
                } else {
                    break;
                }
            },
            else => break,
        }
    }

    if (pos <= start + prefix_len) return null;

    const domain_start = start + prefix_len;
    const path_start = std.mem.findScalarPos(u8, text[0..pos], domain_start, '/') orelse pos;
    const domain = text[domain_start..path_start];
    if (std.mem.findScalar(u8, domain, '.') == null) return null;

    return .{ .end = pos };
}
