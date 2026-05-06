const std = @import("std");
const ts = @import("tree_sitter");
const ansi = @import("ansi.zig");
const theme = @import("theme.zig");
const ts_queries = @import("ts_queries");

// C grammar entry points: upstream tree-sitter grammars no longer ship Zig
// bindings, so we declare the `tree_sitter_<lang>` extern symbols ourselves.
// build.zig compiles each grammar's `src/parser.c` (+ optional `scanner.c`)
// into a static library that exposes these functions.
extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_c() callconv(.c) *const ts.Language;
extern fn tree_sitter_rust() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;
extern fn tree_sitter_python() callconv(.c) *const ts.Language;
extern fn tree_sitter_javascript() callconv(.c) *const ts.Language;
extern fn tree_sitter_bash() callconv(.c) *const ts.Language;
extern fn tree_sitter_cpp() callconv(.c) *const ts.Language;
extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *const ts.Language;
extern fn tree_sitter_html() callconv(.c) *const ts.Language;
extern fn tree_sitter_css() callconv(.c) *const ts.Language;
extern fn tree_sitter_json() callconv(.c) *const ts.Language;

pub const Language = enum {
    zig,
    c,
    rust,
    go,
    python,
    javascript,
    bash,
    cpp,
    typescript,
    tsx,
    html,
    css,
    json,

    pub fn fromString(lang: []const u8) ?Language {
        return language_aliases.get(lang);
    }

    fn index(self: Language) usize {
        return @intFromEnum(self);
    }
};

const language_count = @typeInfo(Language).@"enum".fields.len;
const LanguageAliasMap = std.StaticStringMapWithEql(Language, std.static_string_map.eqlAsciiIgnoreCase);
const language_aliases = LanguageAliasMap.initComptime(.{
    .{ "zig", .zig },
    .{ "c", .c },
    .{ "rust", .rust },
    .{ "rs", .rust },
    .{ "go", .go },
    .{ "python", .python },
    .{ "py", .python },
    .{ "javascript", .javascript },
    .{ "js", .javascript },
    // tree-sitter-javascript parses JSX without TypeScript syntax.
    .{ "jsx", .javascript },
    .{ "bash", .bash },
    .{ "sh", .bash },
    .{ "shell", .bash },
    .{ "cpp", .cpp },
    .{ "c++", .cpp },
    .{ "cxx", .cpp },
    .{ "cc", .cpp },
    .{ "hpp", .cpp },
    .{ "hxx", .cpp },
    .{ "h++", .cpp },
    .{ "typescript", .typescript },
    .{ "ts", .typescript },
    .{ "mts", .typescript },
    .{ "cts", .typescript },
    .{ "tsx", .tsx },
    .{ "html", .html },
    .{ "htm", .html },
    .{ "css", .css },
    .{ "json", .json },
});

const LanguageState = union(enum) {
    uninitialized,
    failed,
    ready: LanguageConfig,
};

const LanguageConfig = struct {
    ts_language: *const ts.Language,
    query: *ts.Query,
};

const QueryState = union(enum) {
    uninitialized,
    failed,
    ready: *ts.Query,
};

const ScopeRef = struct {
    node: ts.Node,
    parent_index: ?u32,
};

const LocalDefinition = struct {
    node: ts.Node,
    scope_index: u32,
    name: []const u8,
};

const Locals = struct {
    scopes: []ScopeRef,
    definitions: []LocalDefinition,

    fn deinit(self: *Locals, allocator: std.mem.Allocator) void {
        allocator.free(self.scopes);
        allocator.free(self.definitions);
    }

    fn build(
        allocator: std.mem.Allocator,
        root: ts.Node,
        query: *const ts.Query,
        source: []const u8,
    ) !Locals {
        var scopes = std.ArrayList(ScopeRef).empty;
        defer scopes.deinit(allocator);

        var definitions = std.ArrayList(ts.Node).empty;
        defer definitions.deinit(allocator);

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query, root);

        while (cursor.nextCapture()) |entry| {
            const capture_index_in_match = entry[0];
            const match = entry[1];
            if (capture_index_in_match >= match.captures.len) continue;

            const capture = match.captures[capture_index_in_match];
            const name = query.captureNameForId(capture.index) orelse "";
            if (std.mem.eql(u8, name, "local.scope")) {
                try scopes.append(allocator, .{
                    .node = capture.node,
                    .parent_index = null,
                });
            } else if (std.mem.eql(u8, name, "local.definition")) {
                try definitions.append(allocator, capture.node);
            }
        }

        for (scopes.items, 0..) |scope, index| {
            scopes.items[index].parent_index = findParentScopeIndex(scope.node, scopes.items);
        }

        var resolved_definitions = std.ArrayList(LocalDefinition).empty;
        defer resolved_definitions.deinit(allocator);
        for (definitions.items) |definition| {
            const scope_index = findEnclosingScopeIndex(definition, scopes.items) orelse continue;
            try resolved_definitions.append(allocator, .{
                .node = definition,
                .scope_index = scope_index,
                .name = nodeText(definition, source),
            });
        }

        return .{
            .scopes = try scopes.toOwnedSlice(allocator),
            .definitions = try resolved_definitions.toOwnedSlice(allocator),
        };
    }

    fn isLocal(self: *const Locals, node: ts.Node, source: []const u8) bool {
        const name = nodeText(node, source);
        var scope_index = findEnclosingScopeIndex(node, self.scopes) orelse return false;
        while (true) {
            for (self.definitions) |definition| {
                if (definition.scope_index != scope_index) continue;
                if (std.mem.eql(u8, definition.name, name)) return true;
            }

            scope_index = self.scopes[scope_index].parent_index orelse return false;
        }
    }
};

const PredicateContext = struct {
    source: []const u8,
    locals: ?*const Locals = null,
};

const StyleIdx = u16;
const no_style: StyleIdx = std.math.maxInt(StyleIdx);
const highlight_max_bytes: usize = 64 * 1024;

const CaptureSpan = struct {
    start: usize,
    end: usize,
    capture_index: StyleIdx,
    pattern_index: u16,

    fn winsOver(self: CaptureSpan, other: CaptureSpan, self_id: usize, other_id: usize) bool {
        if (self.pattern_index != other.pattern_index) return self.pattern_index > other.pattern_index;
        return self_id > other_id;
    }
};

const StyleEvent = struct {
    offset: usize,
    capture_id: usize,
    kind: Kind,

    const Kind = enum { start, end };

    fn lessThanByOffset(_: void, a: StyleEvent, b: StyleEvent) bool {
        return a.offset < b.offset;
    }
};

fn compareActiveCapture(captures: []const CaptureSpan, a: usize, b: usize) std.math.Order {
    if (captures[a].winsOver(captures[b], a, b)) return .lt;
    if (captures[b].winsOver(captures[a], b, a)) return .gt;
    return .eq;
}

const ActiveCaptureQueue = std.PriorityQueue(usize, []const CaptureSpan, compareActiveCapture);

const TreeSitterHighlighter = struct {
    parser: ?*ts.Parser,
    languages: [language_count]LanguageState,
    locals_queries: [language_count]QueryState,

    pub fn init() TreeSitterHighlighter {
        return .{
            .parser = null,
            .languages = [_]LanguageState{.uninitialized} ** language_count,
            .locals_queries = [_]QueryState{.uninitialized} ** language_count,
        };
    }

    pub fn deinit(self: *TreeSitterHighlighter) void {
        for (&self.languages) |*state| {
            switch (state.*) {
                .ready => |cfg| cfg.query.destroy(),
                else => {},
            }
        }
        for (&self.locals_queries) |*state| {
            switch (state.*) {
                .ready => |query| query.destroy(),
                else => {},
            }
        }
        if (self.parser) |parser| parser.destroy();
    }

    /// Overlap semantics: "later pattern wins". More specific patterns that
    /// appear later in `highlights.scm` override earlier generic patterns. Runs
    /// are emitted with a sweep over capture start/end offsets, avoiding a
    /// per-source-byte style table.
    ///
    /// Returns `error.QueryUnavailable` if the language's query cannot be
    /// initialized. Callers must catch this error and fall back to
    /// uniform-color rendering.
    ///
    /// All writes go through `ansi.writeStyled`, which internally calls
    /// `writeSanitized`, preserving the project's sanitization invariant.
    pub fn writeHighlightedBlock(
        self: *TreeSitterHighlighter,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        source: []const u8,
        lang: Language,
        syn_palette: theme.SyntaxPalette,
    ) anyerror!void {
        if (source.len == 0) return;
        if (source.len > highlight_max_bytes) {
            try ansi.writeStyled(writer, true, .{ .fg = syn_palette.plain }, source);
            return;
        }

        const config = self.getOrInitConfig(lang) orelse return error.QueryUnavailable;
        const parser = self.getOrInitParser();

        try parser.setLanguage(config.ts_language);
        const tree = parser.parseString(source, null) orelse return error.QueryUnavailable;
        defer tree.destroy();

        var locals: ?Locals = null;
        defer if (locals) |*l| l.deinit(allocator);
        if (localsSpec(lang) != null) {
            if (self.getOrInitLocalsQuery(lang)) |locals_query| {
                locals = try Locals.build(
                    allocator,
                    tree.rootNode(),
                    locals_query,
                    source,
                );
            }
        }

        const predicate_ctx: PredicateContext = .{
            .source = source,
            .locals = if (locals) |*l| l else null,
        };

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(config.query, tree.rootNode());

        // Tree-sitter's C runtime intentionally does not evaluate predicates
        // such as `#eq?`, `#match?`, `#any-of?`, or `#lua-match?`. The caller
        // is expected to filter matches itself. Without this filtering, every
        // `(identifier) @type (#lua-match? ...)` pattern would match every
        // identifier, letting the highest pattern_index capture win regardless
        // of intent and producing obviously wrong colors.
        // Several grammars also attach editor-only meta captures to real
        // nodes, e.g. `(comment) @comment @spell`. Those meta captures share
        // the same pattern_index and byte range as the real style, so without
        // filtering the final `@memset` in the apply loop could clobber the
        // intended style depending on emit order. Skipping them here keeps
        // the comment/@comment styling intact.
        var caps: std.ArrayList(CaptureSpan) = .empty;
        defer caps.deinit(allocator);
        while (cursor.nextCapture()) |entry| {
            const capture_index_in_match = entry[0];
            const match = entry[1];
            if (capture_index_in_match >= match.captures.len) continue;
            if (!predicatesPass(config.query, match, predicate_ctx)) continue;
            const capture = match.captures[capture_index_in_match];
            const name = config.query.captureNameForId(capture.index) orelse "";
            if (isMetaCapture(name)) continue;
            const start = capture.node.startByte();
            const end = capture.node.endByte();
            if (start >= end) continue;
            if (end > source.len) continue;
            if (capture.index >= no_style) continue;
            try caps.append(allocator, .{
                .start = start,
                .end = end,
                .capture_index = @intCast(capture.index),
                .pattern_index = match.pattern_index,
            });
        }

        try writeCapturedRuns(allocator, writer, source, caps.items, config.query, syn_palette);
    }

    fn getOrInitParser(self: *TreeSitterHighlighter) *ts.Parser {
        if (self.parser) |parser| return parser;
        const parser = ts.Parser.create();
        self.parser = parser;
        return parser;
    }

    pub fn forceLanguageFailedForTesting(self: *TreeSitterHighlighter, lang: Language) void {
        const slot = &self.languages[lang.index()];
        switch (slot.*) {
            .ready => |cfg| cfg.query.destroy(),
            else => {},
        }
        slot.* = .failed;
    }

    fn getOrInitConfig(self: *TreeSitterHighlighter, lang: Language) ?LanguageConfig {
        const slot = &self.languages[lang.index()];
        switch (slot.*) {
            .ready => |cfg| return cfg,
            .failed => return null,
            .uninitialized => {},
        }

        const spec = languageSpec(lang);
        const ts_language = spec.language_fn();

        var error_offset: u32 = 0;
        const query = ts.Query.create(ts_language, spec.highlights, &error_offset) catch {
            slot.* = .failed;
            return null;
        };

        const cfg = LanguageConfig{
            .ts_language = ts_language,
            .query = query,
        };
        slot.* = .{ .ready = cfg };
        return cfg;
    }

    fn getOrInitLocalsQuery(self: *TreeSitterHighlighter, lang: Language) ?*ts.Query {
        const slot = &self.locals_queries[lang.index()];
        switch (slot.*) {
            .ready => |query| return query,
            .failed => return null,
            .uninitialized => {},
        }

        const spec = localsSpec(lang) orelse {
            slot.* = .failed;
            return null;
        };

        const ts_language = spec.language_fn();
        var error_offset: u32 = 0;
        const query = ts.Query.create(ts_language, spec.source, &error_offset) catch {
            slot.* = .failed;
            return null;
        };

        slot.* = .{ .ready = query };
        return query;
    }
};

fn writeCapturedRuns(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    source: []const u8,
    captures: []const CaptureSpan,
    query: *const ts.Query,
    syn_palette: theme.SyntaxPalette,
) !void {
    var state: ansi.StyledState = .{};
    if (captures.len == 0) {
        try ansi.writeStyledRun(writer, true, &state, .{ .fg = syn_palette.plain }, source);
        try ansi.flushStyle(writer, &state);
        return;
    }

    var events: std.ArrayList(StyleEvent) = .empty;
    defer events.deinit(allocator);
    try events.ensureTotalCapacity(allocator, captures.len * 2);
    for (captures, 0..) |capture, id| {
        events.appendAssumeCapacity(.{ .offset = capture.start, .capture_id = id, .kind = .start });
        events.appendAssumeCapacity(.{ .offset = capture.end, .capture_id = id, .kind = .end });
    }
    std.mem.sort(StyleEvent, events.items, {}, StyleEvent.lessThanByOffset);

    const active = try allocator.alloc(bool, captures.len);
    defer allocator.free(active);
    @memset(active, false);

    var active_queue: ActiveCaptureQueue = .initContext(captures);
    defer active_queue.deinit(allocator);
    try active_queue.ensureTotalCapacity(allocator, captures.len);

    var cursor: usize = 0;
    var event_index: usize = 0;
    while (event_index < events.items.len) {
        const offset = events.items[event_index].offset;
        if (cursor < offset) {
            try writeCaptureRun(writer, source[cursor..offset], captures, bestActiveCapture(&active_queue, active), query, syn_palette, &state);
            cursor = offset;
        }

        const group_start = event_index;
        while (event_index < events.items.len and events.items[event_index].offset == offset) : (event_index += 1) {}
        const group = events.items[group_start..event_index];

        for (group) |event| {
            if (event.kind == .end) active[event.capture_id] = false;
        }

        for (group) |event| {
            if (event.kind == .start) {
                active[event.capture_id] = true;
                try active_queue.push(allocator, event.capture_id);
            }
        }
    }

    if (cursor < source.len) {
        try writeCaptureRun(writer, source[cursor..], captures, bestActiveCapture(&active_queue, active), query, syn_palette, &state);
    }
    try ansi.flushStyle(writer, &state);
}

fn bestActiveCapture(active_queue: *ActiveCaptureQueue, active: []const bool) ?usize {
    while (active_queue.peek()) |id| {
        if (active[id]) return id;
        _ = active_queue.pop();
    }
    return null;
}

fn writeCaptureRun(
    writer: *std.Io.Writer,
    bytes: []const u8,
    captures: []const CaptureSpan,
    current_best: ?usize,
    query: *const ts.Query,
    syn_palette: theme.SyntaxPalette,
    state: *ansi.StyledState,
) !void {
    const style: ansi.TextStyle = if (current_best) |id| blk: {
        const name = query.captureNameForId(captures[id].capture_index) orelse "";
        break :blk captureToStyle(name, syn_palette);
    } else .{ .fg = syn_palette.plain };
    try ansi.writeStyledRun(writer, true, state, style, bytes);
}

pub const Highlighter = TreeSitterHighlighter;

const LanguageSpec = struct {
    language_fn: *const fn () callconv(.c) *const ts.Language,
    highlights: []const u8,
};

fn languageSpec(lang: Language) LanguageSpec {
    return switch (lang) {
        .zig => .{
            .language_fn = tree_sitter_zig,
            .highlights = ts_queries.zig_highlights,
        },
        .c => .{
            .language_fn = tree_sitter_c,
            .highlights = ts_queries.c_highlights,
        },
        .rust => .{
            .language_fn = tree_sitter_rust,
            .highlights = ts_queries.rust_highlights,
        },
        .go => .{
            .language_fn = tree_sitter_go,
            .highlights = ts_queries.go_highlights,
        },
        .python => .{
            .language_fn = tree_sitter_python,
            .highlights = ts_queries.python_highlights,
        },
        .javascript => .{
            .language_fn = tree_sitter_javascript,
            .highlights = ts_queries.javascript_highlights,
        },
        .bash => .{
            .language_fn = tree_sitter_bash,
            .highlights = ts_queries.bash_highlights,
        },
        .cpp => .{
            .language_fn = tree_sitter_cpp,
            .highlights = ts_queries.cpp_highlights,
        },
        .typescript => .{
            .language_fn = tree_sitter_typescript,
            .highlights = ts_queries.typescript_highlights,
        },
        .tsx => .{
            .language_fn = tree_sitter_tsx,
            .highlights = ts_queries.tsx_highlights,
        },
        .html => .{
            .language_fn = tree_sitter_html,
            .highlights = ts_queries.html_highlights,
        },
        .css => .{
            .language_fn = tree_sitter_css,
            .highlights = ts_queries.css_highlights,
        },
        .json => .{
            .language_fn = tree_sitter_json,
            .highlights = ts_queries.json_highlights,
        },
    };
}

const LocalsSpec = struct {
    language_fn: *const fn () callconv(.c) *const ts.Language,
    source: []const u8,
};

fn localsSpec(lang: Language) ?LocalsSpec {
    return switch (lang) {
        .javascript => .{
            .language_fn = tree_sitter_javascript,
            .source = ts_queries.javascript_locals,
        },
        .typescript => .{
            .language_fn = tree_sitter_typescript,
            .source = ts_queries.typescript_locals,
        },
        .tsx => .{
            .language_fn = tree_sitter_tsx,
            .source = ts_queries.tsx_locals,
        },
        else => null,
    };
}

fn nodeText(node: ts.Node, source: []const u8) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn findScopeIndex(scopes: []const ScopeRef, node: ts.Node) ?u32 {
    for (scopes, 0..) |scope, index| {
        if (scope.node.eql(node)) return @intCast(index);
    }
    return null;
}

fn findParentScopeIndex(node: ts.Node, scopes: []const ScopeRef) ?u32 {
    var current = node.parent();
    while (current) |parent| : (current = parent.parent()) {
        if (findScopeIndex(scopes, parent)) |index| return index;
    }
    return null;
}

fn findEnclosingScopeIndex(node: ts.Node, scopes: []const ScopeRef) ?u32 {
    var current: ?ts.Node = node;
    while (current) |candidate| : (current = candidate.parent()) {
        if (findScopeIndex(scopes, candidate)) |index| return index;
    }
    return null;
}

const PatternAtom = union(enum) {
    literal: u8,
    digit,
    class: []const u8,
};

fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    if (matchLiteralAlternatives(text, pattern)) |matched| return matched;
    return matchSequentialPattern(text, pattern);
}

fn matchLiteralAlternatives(text: []const u8, pattern: []const u8) ?bool {
    if (pattern.len < 4) return null;
    if (pattern[0] != '^' or pattern[1] != '(') return null;
    if (pattern[pattern.len - 2] != ')' or pattern[pattern.len - 1] != '$') return null;

    const body = pattern[2 .. pattern.len - 2];
    if (std.mem.findAny(u8, body, "[]*+\\") != null) return null;

    var start: usize = 0;
    while (true) {
        const next = std.mem.findScalarPos(u8, body, start, '|') orelse {
            return std.mem.eql(u8, text, body[start..]);
        };
        if (std.mem.eql(u8, text, body[start..next])) return true;
        start = next + 1;
    }
}

fn matchSequentialPattern(text: []const u8, pattern: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    if (p < pattern.len and pattern[p] == '^') p += 1;

    while (p < pattern.len) {
        if (pattern[p] == '$' and p + 1 == pattern.len) {
            return t == text.len;
        }

        const parsed = parsePatternAtom(pattern, p) orelse return false;
        p = parsed.next;

        var min_count: usize = 1;
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    min_count = 0;
                    p += 1;
                },
                '+' => {
                    p += 1;
                },
                else => {},
            }
        }

        var match_count: usize = 0;
        while (t < text.len and atomMatches(parsed.atom, text[t])) : (t += 1) {
            match_count += 1;
            if (p > 0 and pattern[p - 1] != '*' and pattern[p - 1] != '+') break;
        }
        if (match_count < min_count) return false;
    }

    return true;
}

fn parsePatternAtom(pattern: []const u8, start: usize) ?struct { atom: PatternAtom, next: usize } {
    if (start >= pattern.len) return null;
    if (pattern[start] == '[') {
        const end = std.mem.findScalarPos(u8, pattern, start + 1, ']') orelse return null;
        return .{
            .atom = .{ .class = pattern[start + 1 .. end] },
            .next = end + 1,
        };
    }
    if (pattern[start] == '\\') {
        if (start + 1 >= pattern.len) return null;
        return .{
            .atom = switch (pattern[start + 1]) {
                'd' => .digit,
                else => .{ .literal = pattern[start + 1] },
            },
            .next = start + 2,
        };
    }

    return .{
        .atom = .{ .literal = pattern[start] },
        .next = start + 1,
    };
}

fn atomMatches(atom: PatternAtom, byte: u8) bool {
    return switch (atom) {
        .literal => |literal| literal == byte,
        .digit => byte >= '0' and byte <= '9',
        .class => |spec| classContains(spec, byte),
    };
}

fn classContains(spec: []const u8, byte: u8) bool {
    var body = spec;
    var negate = false;
    if (body.len > 0 and body[0] == '^') {
        negate = true;
        body = body[1..];
    }
    const found = classContainsPositive(body, byte);
    return if (negate) !found else found;
}

fn classContainsPositive(spec: []const u8, byte: u8) bool {
    var i: usize = 0;
    while (i < spec.len) {
        if (spec[i] == '\\' and i + 1 < spec.len) {
            const escaped = spec[i + 1];
            if (escaped == 'd') {
                if (byte >= '0' and byte <= '9') return true;
            } else if (byte == escaped) {
                return true;
            }
            i += 2;
            continue;
        }

        if (i + 2 < spec.len and spec[i + 1] == '-') {
            if (byte >= spec[i] and byte <= spec[i + 2]) return true;
            i += 3;
            continue;
        }

        if (byte == spec[i]) return true;
        i += 1;
    }
    return false;
}

/// Tree-sitter's C runtime does not apply query predicates. This helper walks
/// the raw predicate token stream and implements the subset used by the
/// shipped highlight queries.
fn predicatesPass(
    query: *const ts.Query,
    match: ts.Query.Match,
    ctx: PredicateContext,
) bool {
    const steps = query.predicatesForPattern(match.pattern_index);
    if (steps.len == 0) return true;

    var i: usize = 0;
    while (i < steps.len) {
        var j = i;
        while (j < steps.len and steps[j].type != .done) : (j += 1) {}
        const pred = steps[i..j];
        i = j + 1;

        if (pred.len == 0) continue;
        if (pred[0].type != .string) return false;
        const name = query.stringValueForId(pred[0].value_id) orelse return false;
        const args = pred[1..];

        const ok = evaluateSinglePredicate(name, args, query, match, ctx);
        if (!ok) return false;
    }
    return true;
}

fn evaluateSinglePredicate(
    name: []const u8,
    args: []const ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    ctx: PredicateContext,
) bool {
    // Tree-sitter distinguishes two kinds of `#name`-prefixed forms:
    //   * Predicates (end with `?`) filter matches — e.g. `#eq?`, `#match?`.
    //   * Directives (end with `!`) attach metadata to a pattern but never
    //     filter it — e.g. `#set! "priority" 95`.
    // Directives must always be treated as "pass" so the associated capture
    // still fires; rejecting them would, for example, drop
    // `(multiline_string) @string (#set! "priority" 95)` from tree-sitter-zig
    // and cause string literals to regress to plain color.
    if (name.len > 0 and name[name.len - 1] == '!') return true;

    if (std.mem.eql(u8, name, "eq?")) {
        return predEq(args, query, match, ctx.source, false);
    }
    if (std.mem.eql(u8, name, "not-eq?")) {
        return predEq(args, query, match, ctx.source, true);
    }
    if (std.mem.eql(u8, name, "any-of?")) {
        return predAnyOf(args, query, match, ctx.source, false);
    }
    if (std.mem.eql(u8, name, "not-any-of?")) {
        return predAnyOf(args, query, match, ctx.source, true);
    }
    if (std.mem.eql(u8, name, "match?")) {
        return predMatch(args, query, match, ctx.source, false);
    }
    if (std.mem.eql(u8, name, "not-match?")) {
        return predMatch(args, query, match, ctx.source, true);
    }
    if (std.mem.eql(u8, name, "lua-match?")) {
        return predMatch(args, query, match, ctx.source, false);
    }
    if (std.mem.eql(u8, name, "is-not?")) {
        return predIsNot(args, query, match, ctx);
    }
    return false;
}

fn predEq(
    args: []const ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
    negated: bool,
) bool {
    if (args.len != 2) return false;
    const lhs = resolvePredicateText(args[0], query, match, source) orelse return false;
    const rhs = resolvePredicateText(args[1], query, match, source) orelse return false;
    const eq = std.mem.eql(u8, lhs, rhs);
    return if (negated) !eq else eq;
}

fn predAnyOf(
    args: []const ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
    negated: bool,
) bool {
    if (args.len < 2) return false;
    const capture_text = resolvePredicateText(args[0], query, match, source) orelse return false;
    for (args[1..]) |arg| {
        if (arg.type != .string) continue;
        const literal = query.stringValueForId(arg.value_id) orelse continue;
        if (std.mem.eql(u8, capture_text, literal)) return !negated;
    }
    return negated;
}

fn predMatch(
    args: []const ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
    negated: bool,
) bool {
    if (args.len != 2) return false;
    const text = resolvePredicateText(args[0], query, match, source) orelse return false;
    if (args[1].type != .string) return false;
    const pattern = query.stringValueForId(args[1].value_id) orelse return false;
    const matched = matchesPattern(text, pattern);
    return if (negated) !matched else matched;
}

fn predIsNot(
    args: []const ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    ctx: PredicateContext,
) bool {
    if (args.len != 1) return false;
    if (args[0].type != .string) return false;
    const property = query.stringValueForId(args[0].value_id) orelse return false;
    if (!std.mem.eql(u8, property, "local")) return false;

    const locals = ctx.locals orelse return false;
    if (match.captures.len == 0) return false;
    return !locals.isLocal(match.captures[0].node, ctx.source);
}

fn resolvePredicateText(
    step: ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    switch (step.type) {
        .string => return query.stringValueForId(step.value_id),
        .capture => {
            for (match.captures) |c| {
                if (c.index == step.value_id) {
                    return source[c.node.startByte()..c.node.endByte()];
                }
            }
            return null;
        },
        .done => return null,
    }
}

fn captureToStyle(name: []const u8, sp: theme.SyntaxPalette) ansi.TextStyle {
    if (std.mem.startsWith(u8, name, "keyword")) return .{ .fg = sp.keyword, .bold = true };
    if (std.mem.startsWith(u8, name, "type")) return .{ .fg = sp.type_name };
    if (std.mem.startsWith(u8, name, "string") or std.mem.startsWith(u8, name, "character")) return .{ .fg = sp.string };
    if (std.mem.startsWith(u8, name, "comment")) return .{ .fg = sp.comment, .italic = true };
    if (std.mem.startsWith(u8, name, "number") or std.mem.startsWith(u8, name, "constant.numeric")) return .{ .fg = sp.number };
    if (std.mem.startsWith(u8, name, "function") or std.mem.startsWith(u8, name, "constant.builtin")) return .{ .fg = sp.func };
    if (std.mem.startsWith(u8, name, "operator") or std.mem.startsWith(u8, name, "punctuation")) return .{ .fg = sp.operator };
    // HTML/CSS prefixes; placed last so existing languages keep their
    // colors. `variable` and generic `constant` catch-alls are omitted
    // because Rust and Python use those capture names too.
    if (std.mem.startsWith(u8, name, "tag")) return .{ .fg = sp.keyword };
    if (std.mem.startsWith(u8, name, "attribute")) return .{ .fg = sp.func };
    if (std.mem.startsWith(u8, name, "property")) return .{ .fg = sp.type_name };
    return .{ .fg = sp.plain };
}

/// Capture names that editors (Neovim, Helix) use for non-visual purposes
/// — spell checking, concealment, language injection — but that Tree-sitter
/// grammars still emit as regular captures. Skipping them at collection time
/// prevents them from overwriting real styles when two captures share the
/// same byte range, e.g. `(comment) @comment @spell`.
const meta_capture_names = [_][]const u8{
    "spell",
    "nospell",
    "embedded",
    "none",
    "conceal",
};

fn isMetaCapture(name: []const u8) bool {
    for (meta_capture_names) |meta| {
        if (std.mem.eql(u8, name, meta)) return true;
    }
    return false;
}

test "Language.fromString recognizes all supported names and aliases" {
    try std.testing.expectEqual(Language.zig, Language.fromString("zig").?);
    try std.testing.expectEqual(Language.zig, Language.fromString("Zig").?);
    try std.testing.expectEqual(Language.c, Language.fromString("c").?);
    try std.testing.expectEqual(Language.rust, Language.fromString("rust").?);
    try std.testing.expectEqual(Language.rust, Language.fromString("rs").?);
    try std.testing.expectEqual(Language.go, Language.fromString("go").?);
    try std.testing.expectEqual(Language.python, Language.fromString("python").?);
    try std.testing.expectEqual(Language.python, Language.fromString("py").?);
    try std.testing.expectEqual(Language.javascript, Language.fromString("javascript").?);
    try std.testing.expectEqual(Language.javascript, Language.fromString("js").?);
    try std.testing.expectEqual(Language.javascript, Language.fromString("jsx").?);
    try std.testing.expectEqual(Language.bash, Language.fromString("bash").?);
    try std.testing.expectEqual(Language.bash, Language.fromString("sh").?);
    try std.testing.expectEqual(Language.bash, Language.fromString("shell").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("cpp").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("c++").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("CXX").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("cc").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("hpp").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("hxx").?);
    try std.testing.expectEqual(Language.cpp, Language.fromString("h++").?);
    try std.testing.expectEqual(Language.typescript, Language.fromString("typescript").?);
    try std.testing.expectEqual(Language.typescript, Language.fromString("ts").?);
    try std.testing.expectEqual(Language.typescript, Language.fromString("mts").?);
    try std.testing.expectEqual(Language.typescript, Language.fromString("cts").?);
    try std.testing.expectEqual(Language.tsx, Language.fromString("tsx").?);
    try std.testing.expectEqual(Language.tsx, Language.fromString("TSX").?);
    try std.testing.expectEqual(Language.html, Language.fromString("html").?);
    try std.testing.expectEqual(Language.html, Language.fromString("HTM").?);
    try std.testing.expectEqual(Language.css, Language.fromString("css").?);
    try std.testing.expectEqual(Language.json, Language.fromString("json").?);
    try std.testing.expectEqual(@as(?Language, null), Language.fromString(""));
    try std.testing.expectEqual(@as(?Language, null), Language.fromString("klingon"));
}

test "Highlighter: parser is created lazily" {
    var hl = Highlighter.init();
    defer hl.deinit();

    try std.testing.expectEqual(@as(?*ts.Parser, null), hl.parser);

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try hl.writeHighlightedBlock(allocator, &buf.writer, "const x = 1;", .zig, theme.default_syntax_palette);
    try std.testing.expect(hl.parser != null);
}

test "captureToStyle: keyword prefix matches dotted captures" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("keyword.control", sp);
    try std.testing.expectEqual(sp.keyword, s.fg.?);
    try std.testing.expect(s.bold);
}

test "captureToStyle: function.builtin maps to func" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("function.builtin", sp);
    try std.testing.expectEqual(sp.func, s.fg.?);
}

test "matchesPattern handles anchored alternation and classes" {
    try std.testing.expect(matchesPattern("require", "^(require|module)$"));
    try std.testing.expect(matchesPattern("MyType", "^[A-Z_][a-zA-Z0-9_]*"));
    try std.testing.expect(!matchesPattern("not_builtin", "^(require|module)$"));
    try std.testing.expect(!matchesPattern("myType", "^[A-Z_][a-zA-Z0-9_]*"));
}

test "matchesPattern handles negated character classes" {
    try std.testing.expect(matchesPattern("div", "^[a-z][^.]*$"));
    try std.testing.expect(matchesPattern("my-tag", "^[a-z][^.]*$"));
    try std.testing.expect(!matchesPattern("my.tag", "^[a-z][^.]*$"));
    try std.testing.expect(!matchesPattern("Div", "^[a-z][^.]*$"));
}

test "captureToStyle: unknown capture name falls back to plain" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("namespace", sp);
    try std.testing.expectEqual(sp.plain, s.fg.?);
}

test "captureToStyle: tag maps to keyword color without bold" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("tag", sp);
    try std.testing.expectEqual(sp.keyword, s.fg.?);
    try std.testing.expect(!s.bold);
}

test "captureToStyle: tag.delimiter inherits tag mapping via prefix match" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("tag.delimiter", sp);
    try std.testing.expectEqual(sp.keyword, s.fg.?);
    try std.testing.expect(!s.bold);
}

test "captureToStyle: attribute maps to func color" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("attribute", sp);
    try std.testing.expectEqual(sp.func, s.fg.?);
}

test "captureToStyle: property maps to type_name color" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("property", sp);
    try std.testing.expectEqual(sp.type_name, s.fg.?);
}

test "captureToStyle: comment is italic" {
    const sp: theme.SyntaxPalette = theme.default_syntax_palette;
    const s = captureToStyle("comment.documentation", sp);
    try std.testing.expectEqual(sp.comment, s.fg.?);
    try std.testing.expect(s.italic);
}

test "Highlighter: lazy init + reuse of Zig query" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const first = hl.getOrInitConfig(.zig).?;
    const second = hl.getOrInitConfig(.zig).?;
    try std.testing.expectEqual(first.query, second.query);
}

test "Highlighter: writes styled zig source" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "const x: u32 = 42;";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b["));
}

test "Highlighter: highlights every supported language end-to-end" {
    const allocator = std.testing.allocator;
    var hl = Highlighter.init();
    defer hl.deinit();

    const cases = [_]struct { lang: Language, source: []const u8, expected_token: []const u8 }{
        .{ .lang = .c, .source = "int main(void) { return 0; }", .expected_token = "return" },
        .{ .lang = .rust, .source = "fn main() { let x = 1; }", .expected_token = "let" },
        .{ .lang = .go, .source = "package main\nfunc main() {}", .expected_token = "package" },
        .{ .lang = .python, .source = "def greet():\n    return 1\n", .expected_token = "def" },
        .{ .lang = .javascript, .source = "const x = 1;\n", .expected_token = "const" },
        .{ .lang = .bash, .source = "echo hello\n", .expected_token = "echo" },
        .{ .lang = .cpp, .source = "int main() { return 0; }", .expected_token = "return" },
        .{ .lang = .typescript, .source = "const x: number = 1;\n", .expected_token = "const" },
        .{ .lang = .tsx, .source = "const el = <div>hi</div>;\n", .expected_token = "const" },
        .{ .lang = .html, .source = "<p>hello</p>\n", .expected_token = "p" },
        .{ .lang = .css, .source = ".a { color: red; }\n", .expected_token = "color" },
        .{ .lang = .json, .source = "{\"k\": 1}\n", .expected_token = "1" },
    };

    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();

        try hl.writeHighlightedBlock(allocator, &buf.writer, case.source, case.lang, theme.default_syntax_palette);

        var list = buf.toArrayList();
        defer list.deinit(allocator);
        const rendered = try list.toOwnedSlice(allocator);
        defer allocator.free(rendered);

        try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, case.expected_token));
        try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b["));
    }
}

const func_ansi = "\x1b[38;2;38;139;210m";
const plain_ansi = "\x1b[38;2;131;148;150m";
const keyword_ansi = "\x1b[38;2;133;153;0m";

test "Highlighter: later @function pattern overrides generic @variable on fn decl name" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "fn greet() void {}";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    const combined = func_ansi ++ "greet";
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, combined));
}

test "Highlighter: uncaptured whitespace renders with plain color" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "const x = 1;";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, plain_ansi));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi));
}

test "Highlighter: @string captures survive a #set! directive on the pattern" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "const msg = \"hi\";";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    const string_color = "\x1b[38;2;42;161;152m";
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, string_color));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "hi"));
}

test "Highlighter: lua-match highlights Zig type identifiers" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "const value: MyType = undefined;";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    const type_color = "\x1b[38;2;181;137;0m";
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, type_color ++ "MyType"));
}

test "Highlighter: javascript require is builtin when not shadowed" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "require('fs');";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .javascript, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "require"));
}

test "Highlighter: javascript local require does not use builtin styling" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "function demo(require) { return require; }";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .javascript, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "require"));
}

test "Highlighter: @spell meta capture does not override @comment italic" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "// hello world";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.default_syntax_palette);

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    const comment_color = "\x1b[38;2;88;110;117m";
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, comment_color));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "hello world"));
}

test "Highlighter: forced .failed returns QueryUnavailable" {
    var hl = Highlighter.init();
    defer hl.deinit();
    hl.forceLanguageFailedForTesting(.zig);

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try std.testing.expectError(
        error.QueryUnavailable,
        hl.writeHighlightedBlock(allocator, &buf.writer, "const x = 1;", .zig, theme.default_syntax_palette),
    );
}

test "Highlighter: .failed is sticky across repeated calls" {
    var hl = Highlighter.init();
    defer hl.deinit();
    hl.forceLanguageFailedForTesting(.zig);

    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    for (0..3) |_| {
        try std.testing.expectError(
            error.QueryUnavailable,
            hl.writeHighlightedBlock(allocator, &buf.writer, "x", .zig, theme.default_syntax_palette),
        );
    }
    switch (hl.languages[Language.zig.index()]) {
        .failed => {},
        else => return error.TestExpectedFailedState,
    }
}

test "Highlighter: forcing .failed on a .ready language frees the old query" {
    var hl = Highlighter.init();
    defer hl.deinit();

    _ = hl.getOrInitConfig(.zig).?;
    switch (hl.languages[Language.zig.index()]) {
        .ready => {},
        else => return error.TestExpectedReadyState,
    }

    hl.forceLanguageFailedForTesting(.zig);
    switch (hl.languages[Language.zig.index()]) {
        .failed => {},
        else => return error.TestExpectedFailedState,
    }
}

const string_ansi = "\x1b[38;2;42;161;152m";
const number_ansi = "\x1b[38;2;211;54;130m";
const type_name_ansi = "\x1b[38;2;181;137;0m";

fn renderHighlightedForTest(
    hl: *Highlighter,
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: Language,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, lang, theme.default_syntax_palette);
    var list = buf.toArrayList();
    defer list.deinit(allocator);
    return try list.toOwnedSlice(allocator);
}

test "Highlighter: cpp keeps c primitive types via comptime query concat" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "int main() { return 0; }", .cpp);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi ++ "return"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, type_name_ansi ++ "int"));
}

test "Highlighter: typescript highlights const and number type" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "const x: number = 1;\n", .typescript);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi ++ "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, type_name_ansi ++ "number"));
}

test "Highlighter: tsx highlights const in function form" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "const greet = (name: string) => name;\n", .tsx);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi ++ "const"));
}

test "Highlighter: html colors tag names via the tag prefix branch" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "<p>hello</p>\n", .html);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi ++ "p"));
}

test "Highlighter: css colors property names via the property prefix branch" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, ".a { color: red; }\n", .css);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, type_name_ansi ++ "color"));
}

test "Highlighter: json colors keys as strings and numbers as numbers" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "{\"k\": 1}\n", .json);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, string_ansi ++ "\"k\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, number_ansi ++ "1"));
}

test "Highlighter: tsx highlights jsx tag and attribute" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const source = "const el = <div className=\"hi\">text</div>;\n";
    const rendered = try renderHighlightedForTest(&hl, allocator, source, .tsx);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi ++ "div"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "className"));
}

test "Highlighter: javascript highlights jsx tag when used as jsx alias" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "const el = <span>hi</span>;\n", .javascript);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi ++ "span"));
}

test "Highlighter: typescript require is builtin when not shadowed" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "require('fs');", .typescript);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "require"));
}

test "Highlighter: typescript local require does not use builtin styling" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "function demo(require) { return require; }", .typescript);
    defer allocator.free(rendered);

    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "require"));
}

test "Highlighter: tsx require is builtin when not shadowed" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "require('fs');", .tsx);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "require"));
}

test "Highlighter: tsx local require does not use builtin styling" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const rendered = try renderHighlightedForTest(&hl, allocator, "function demo(require) { return require; }", .tsx);
    defer allocator.free(rendered);

    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, func_ansi ++ "require"));
}

test "Highlighter: large fenced block above threshold falls back to plain style" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u8, highlight_max_bytes + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    const rendered = try renderHighlightedForTest(&hl, allocator, big, .zig);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, plain_ansi));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, keyword_ansi));
}
