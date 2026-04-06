const std = @import("std");
const ts = @import("tree_sitter");
const ansi = @import("../ansi.zig");
const theme = @import("../theme.zig");
const tree_sitter_zig = @import("tree-sitter-zig");
const ts_queries = @import("ts_queries");

// C grammar entry points: upstream tree-sitter grammars no longer ship Zig
// bindings, so we declare the `tree_sitter_<lang>` extern symbols ourselves.
// build.zig compiles each grammar's `src/parser.c` (+ optional `scanner.c`)
// into a static library that exposes these functions.
extern fn tree_sitter_c() callconv(.c) *const anyopaque;
extern fn tree_sitter_rust() callconv(.c) *const anyopaque;
extern fn tree_sitter_go() callconv(.c) *const anyopaque;
extern fn tree_sitter_python() callconv(.c) *const anyopaque;
extern fn tree_sitter_javascript() callconv(.c) *const anyopaque;
extern fn tree_sitter_bash() callconv(.c) *const anyopaque;

/// Languages currently supported for syntax highlighting in code fences.
pub const Language = enum {
    zig,
    c,
    rust,
    go,
    python,
    javascript,
    bash,

    /// Map a code fence language string (e.g. from `Fence.language`) to a
    /// `Language` value, returning `null` for unrecognized languages so the
    /// caller can fall back to uniform-color rendering.
    pub fn fromString(lang: []const u8) ?Language {
        if (lang.len == 0) return null;
        if (eqIgnoreAscii(lang, "zig")) return .zig;
        if (eqIgnoreAscii(lang, "c")) return .c;
        if (eqIgnoreAscii(lang, "rust") or eqIgnoreAscii(lang, "rs")) return .rust;
        if (eqIgnoreAscii(lang, "go")) return .go;
        if (eqIgnoreAscii(lang, "python") or eqIgnoreAscii(lang, "py")) return .python;
        if (eqIgnoreAscii(lang, "javascript") or eqIgnoreAscii(lang, "js")) return .javascript;
        if (eqIgnoreAscii(lang, "bash") or eqIgnoreAscii(lang, "sh") or eqIgnoreAscii(lang, "shell")) return .bash;
        return null;
    }

    fn index(self: Language) usize {
        return @intFromEnum(self);
    }
};

const language_count = @typeInfo(Language).@"enum".fields.len;

/// Three-state lazy language initialization.
/// Distinguishes "not yet tried" from "tried and failed" so the Highlighter
/// does not repeatedly reattempt a broken query.
const LanguageState = union(enum) {
    uninitialized,
    failed,
    ready: LanguageConfig,
};

const LanguageConfig = struct {
    ts_language: *const ts.Language,
    query: *ts.Query,
};

/// Sentinel stored in the per-byte style array to mark "no capture covers
/// this byte". `u32` maps directly onto Tree-sitter's capture index type
/// returned by `QueryCursor.nextCapture()`.
const no_style: u32 = std.math.maxInt(u32);

/// A single capture's byte range, paired with its owning pattern index.
/// Stored during capture collection so the apply step can sort by
/// `pattern_index` and let later patterns overwrite earlier ones.
const CaptureSpan = struct {
    start: usize,
    end: usize,
    capture_index: u32,
    pattern_index: u16,

    fn lessThanByPattern(_: void, a: CaptureSpan, b: CaptureSpan) bool {
        return a.pattern_index < b.pattern_index;
    }
};

pub const Highlighter = struct {
    parser: *ts.Parser,
    languages: [language_count]LanguageState,

    pub fn init() Highlighter {
        return .{
            .parser = ts.Parser.create(),
            .languages = [_]LanguageState{.uninitialized} ** language_count,
        };
    }

    pub fn deinit(self: *Highlighter) void {
        for (&self.languages) |*state| {
            switch (state.*) {
                .ready => |cfg| cfg.query.destroy(),
                else => {},
            }
        }
        self.parser.destroy();
    }

    /// Highlight `source` and write ANSI-styled output to `writer`.
    ///
    /// Overlap semantics: "later pattern wins". Captures are collected, sorted
    /// by `pattern_index` ascending, then applied to a per-byte style-index
    /// array via `@memset`. Since a later `@memset` overwrites an earlier one,
    /// more specific patterns that appear later in `highlights.scm` override
    /// earlier generic patterns. This matches Tree-sitter's standard highlight
    /// library behavior and the project plan.
    ///
    /// Returns `error.QueryUnavailable` if the language's query cannot be
    /// initialized. Callers must catch this error and fall back to
    /// uniform-color rendering.
    ///
    /// All writes go through `ansi.writeStyled`, which internally calls
    /// `writeSanitized`, preserving the project's sanitization invariant.
    pub fn writeHighlightedBlock(
        self: *Highlighter,
        allocator: std.mem.Allocator,
        writer: *std.io.Writer,
        source: []const u8,
        lang: Language,
        syn_palette: theme.SyntaxPalette,
    ) !void {
        if (source.len == 0) return;

        const config = self.getOrInitConfig(lang) orelse return error.QueryUnavailable;

        try self.parser.setLanguage(config.ts_language);
        const tree = self.parser.parseString(source, null) orelse return error.QueryUnavailable;
        defer tree.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(config.query, tree.rootNode());

        // 1. Collect every capture whose pattern's predicates all pass and
        //    whose name is not a visual-editor meta capture.
        //
        // Tree-sitter's C runtime intentionally does not evaluate predicates
        // such as `#eq?`, `#match?`, `#any-of?`, or `#lua-match?`. The caller
        // is expected to filter matches itself. Without this filtering, every
        // `(identifier) @type (#lua-match? ...)` pattern would match every
        // identifier, letting the highest pattern_index capture win regardless
        // of intent and producing obviously wrong colors.
        //
        // Several grammars also attach editor-only meta captures to real
        // nodes, e.g. `(comment) @comment @spell`. Those meta captures share
        // the same pattern_index and byte range as the real style, so without
        // filtering the final `@memset` in the apply loop could clobber the
        // intended style depending on emit order. Skipping them here keeps
        // the comment/@comment styling intact.
        var caps: std.ArrayListUnmanaged(CaptureSpan) = .empty;
        defer caps.deinit(allocator);
        while (cursor.nextCapture()) |entry| {
            const capture_index_in_match = entry[0];
            const match = entry[1];
            if (capture_index_in_match >= match.captures.len) continue;
            if (!predicatesPass(config.query, match, source)) continue;
            const capture = match.captures[capture_index_in_match];
            const name = config.query.captureNameForId(capture.index) orelse "";
            if (isMetaCapture(name)) continue;
            const start = capture.node.startByte();
            const end = capture.node.endByte();
            if (start >= end) continue;
            if (end > source.len) continue;
            try caps.append(allocator, .{
                .start = start,
                .end = end,
                .capture_index = capture.index,
                .pattern_index = match.pattern_index,
            });
        }

        // 2. Sort by pattern_index ascending so later patterns overwrite earlier
        //    ones during the @memset pass.
        std.mem.sort(CaptureSpan, caps.items, {}, CaptureSpan.lessThanByPattern);

        // 3. Build a per-byte style-index array. Sentinel NO_STYLE means
        //    "no capture covers this byte — render as plain".
        const styles = try allocator.alloc(u32, source.len);
        defer allocator.free(styles);
        @memset(styles, no_style);
        for (caps.items) |c| {
            @memset(styles[c.start..c.end], c.capture_index);
        }

        // 4. Emit runs of consecutive bytes sharing the same style. Every write
        //    goes through ansi.writeStyled, keeping the sanitization invariant.
        var run_start: usize = 0;
        while (run_start < source.len) {
            const cur = styles[run_start];
            var run_end = run_start + 1;
            while (run_end < source.len and styles[run_end] == cur) : (run_end += 1) {}

            const slice = source[run_start..run_end];
            const style: ansi.TextStyle = if (cur == no_style)
                .{ .fg = syn_palette.plain }
            else blk: {
                const name = config.query.captureNameForId(cur) orelse "";
                break :blk captureToStyle(name, syn_palette);
            };
            try ansi.writeStyled(writer, true, style, slice);
            run_start = run_end;
        }
    }

    /// Test-only hook: force a language into `.failed` so callers can
    /// verify the `error.QueryUnavailable` fallback path without relying
    /// on a real broken `highlights.scm`.
    pub fn forceLanguageFailedForTesting(self: *Highlighter, lang: Language) void {
        const slot = &self.languages[lang.index()];
        switch (slot.*) {
            .ready => |cfg| cfg.query.destroy(),
            else => {},
        }
        slot.* = .failed;
    }

    fn getOrInitConfig(self: *Highlighter, lang: Language) ?LanguageConfig {
        const slot = &self.languages[lang.index()];
        switch (slot.*) {
            .ready => |cfg| return cfg,
            .failed => return null,
            .uninitialized => {},
        }

        const spec = languageSpec(lang);
        const ts_language: *const ts.Language = @ptrCast(spec.language_fn());

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
};

const LanguageSpec = struct {
    language_fn: *const fn () *const anyopaque,
    highlights: []const u8,
};

fn languageSpec(lang: Language) LanguageSpec {
    return switch (lang) {
        .zig => .{
            .language_fn = tree_sitter_zig.language,
            .highlights = ts_queries.zig_highlights,
        },
        .c => .{
            .language_fn = @ptrCast(&tree_sitter_c),
            .highlights = ts_queries.c_highlights,
        },
        .rust => .{
            .language_fn = @ptrCast(&tree_sitter_rust),
            .highlights = ts_queries.rust_highlights,
        },
        .go => .{
            .language_fn = @ptrCast(&tree_sitter_go),
            .highlights = ts_queries.go_highlights,
        },
        .python => .{
            .language_fn = @ptrCast(&tree_sitter_python),
            .highlights = ts_queries.python_highlights,
        },
        .javascript => .{
            .language_fn = @ptrCast(&tree_sitter_javascript),
            .highlights = ts_queries.javascript_highlights,
        },
        .bash => .{
            .language_fn = @ptrCast(&tree_sitter_bash),
            .highlights = ts_queries.bash_highlights,
        },
    };
}

/// Evaluate the predicates attached to a query pattern against one match.
///
/// Tree-sitter's C runtime does not apply `#eq?`, `#match?`, `#any-of?`,
/// or grammar-specific extensions like `#lua-match?` — it simply returns the
/// raw predicate token stream. This helper walks that stream and implements
/// the minimal subset we need for highlights.scm:
///
///   * `#eq?`, `#not-eq?`          — literal / capture-text equality
///   * `#any-of?`, `#not-any-of?`  — membership in a list of literals
///
/// Regex predicates (`#match?`, `#not-match?`) and editor-specific ones
/// (`#lua-match?`, `#is-not?`) are rejected (match fails closed). This loses
/// some regex-based highlighting but prevents the much worse failure mode of
/// every predicated pattern matching every input.
fn predicatesPass(
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
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
        // The first step of a predicate must be a string — the predicate name.
        if (pred[0].type != .string) return false;
        const name = query.stringValueForId(pred[0].value_id) orelse return false;
        const args = pred[1..];

        const ok = evaluateSinglePredicate(name, args, query, match, source);
        if (!ok) return false;
    }
    return true;
}

fn evaluateSinglePredicate(
    name: []const u8,
    args: []const ts.Query.PredicateStep,
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
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
        return predEq(args, query, match, source, false);
    }
    if (std.mem.eql(u8, name, "not-eq?")) {
        return predEq(args, query, match, source, true);
    }
    if (std.mem.eql(u8, name, "any-of?")) {
        return predAnyOf(args, query, match, source, false);
    }
    if (std.mem.eql(u8, name, "not-any-of?")) {
        return predAnyOf(args, query, match, source, true);
    }
    // `#match?`, `#not-match?`, `#lua-match?`, `#is-not?`, and any other
    // unknown predicates fall through and cause the match to be rejected.
    // This is deliberately conservative: see the doc comment on
    // `predicatesPass` for rationale.
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

/// Resolve a single `PredicateStep` to a `[]const u8`:
///   - `.capture` → the text slice of a capture bound in this match
///   - `.string`  → the literal stored in the query
///   - `.done`    → error (null)
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

/// Map a Tree-sitter capture name (possibly dotted, e.g. `keyword.control`)
/// to a terminal text style using prefix matching. Unknown capture names
/// fall back to `syn_palette.plain`.
fn captureToStyle(name: []const u8, sp: theme.SyntaxPalette) ansi.TextStyle {
    if (startsWith(name, "keyword")) return .{ .fg = sp.keyword, .bold = true };
    if (startsWith(name, "type")) return .{ .fg = sp.type_name };
    if (startsWith(name, "string") or startsWith(name, "character")) return .{ .fg = sp.string };
    if (startsWith(name, "comment")) return .{ .fg = sp.comment, .italic = true };
    if (startsWith(name, "number") or startsWith(name, "constant.numeric")) return .{ .fg = sp.number };
    if (startsWith(name, "function") or startsWith(name, "constant.builtin")) return .{ .fg = sp.func };
    if (startsWith(name, "operator") or startsWith(name, "punctuation")) return .{ .fg = sp.operator };
    return .{ .fg = sp.plain };
}

fn startsWith(name: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix);
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

fn eqIgnoreAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
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
    try std.testing.expectEqual(Language.bash, Language.fromString("bash").?);
    try std.testing.expectEqual(Language.bash, Language.fromString("sh").?);
    try std.testing.expectEqual(Language.bash, Language.fromString("shell").?);
    try std.testing.expectEqual(@as(?Language, null), Language.fromString(""));
    try std.testing.expectEqual(@as(?Language, null), Language.fromString("klingon"));
}

test "captureToStyle: keyword prefix matches dotted captures" {
    const sp: theme.SyntaxPalette = theme.syntaxPalette(.solarized_dark);
    const s = captureToStyle("keyword.control", sp);
    try std.testing.expectEqual(sp.keyword, s.fg.?);
    try std.testing.expect(s.bold);
}

test "captureToStyle: function.builtin maps to func" {
    const sp: theme.SyntaxPalette = theme.syntaxPalette(.solarized_dark);
    const s = captureToStyle("function.builtin", sp);
    try std.testing.expectEqual(sp.func, s.fg.?);
}

test "captureToStyle: unknown capture name falls back to plain" {
    const sp: theme.SyntaxPalette = theme.syntaxPalette(.solarized_dark);
    const s = captureToStyle("tag", sp);
    try std.testing.expectEqual(sp.plain, s.fg.?);
}

test "captureToStyle: comment is italic" {
    const sp: theme.SyntaxPalette = theme.syntaxPalette(.solarized_dark);
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
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const source = "const x: u32 = 42;";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.syntaxPalette(.solarized_dark));

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
    };

    for (cases) |case| {
        var buf: std.io.Writer.Allocating = .init(allocator);
        defer buf.deinit();

        try hl.writeHighlightedBlock(allocator, &buf.writer, case.source, case.lang, theme.syntaxPalette(.solarized_dark));

        var list = buf.toArrayList();
        defer list.deinit(allocator);
        const rendered = try list.toOwnedSlice(allocator);
        defer allocator.free(rendered);

        try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, case.expected_token));
        try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b["));
    }
}

const func_ansi = "\x1b[38;2;38;139;210m"; // sp.func    — blue  #268bd2
const plain_ansi = "\x1b[38;2;131;148;150m"; // sp.plain   — base0 #839496
const keyword_ansi = "\x1b[38;2;133;153;0m"; // sp.keyword — green #859900

test "Highlighter: later @function pattern overrides generic @variable on fn decl name" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    // tree-sitter-zig's highlights.scm starts with `(identifier) @variable`,
    // then later adds
    //   (function_declaration name: (identifier) @function)
    // Without "later pattern wins", `greet` would stay @variable (plain).
    // With the fix it must flip to @function (blue).
    const source = "fn greet() void {}";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.syntaxPalette(.solarized_dark));

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    // The func ANSI escape must be the style emitted right before `greet`.
    const combined = func_ansi ++ "greet";
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, combined));
}

test "Highlighter: uncaptured whitespace renders with plain color" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    // Spaces between identifiers/operators are not captured by any pattern
    // in highlights.scm, so they must flow through the `plain` fallback.
    const source = "const x = 1;";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.syntaxPalette(.solarized_dark));

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
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    // tree-sitter-zig's highlights.scm pattern for strings ends with
    // `(#set! "priority" 95)`. `#set!` is a directive, not a predicate,
    // so the capture must still fire and the literal must be rendered
    // with the `.string` palette slot (cyan #2aa198 = 42,161,152).
    const source = "const msg = \"hi\";";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.syntaxPalette(.solarized_dark));

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    const string_color = "\x1b[38;2;42;161;152m";
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, string_color));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "hi"));
}

test "Highlighter: @spell meta capture does not override @comment italic" {
    var hl = Highlighter.init();
    defer hl.deinit();

    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    // tree-sitter-zig's highlights.scm ends with:
    //   (comment) @comment @spell
    // Both captures fire for the same node and same pattern index. Without
    // the meta-capture filter, @spell would race with @comment and could
    // overwrite the comment style with plain depending on emit order.
    const source = "// hello world";
    try hl.writeHighlightedBlock(allocator, &buf.writer, source, .zig, theme.syntaxPalette(.solarized_dark));

    var list = buf.toArrayList();
    defer list.deinit(allocator);
    const rendered = try list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    // The italic SGR (\x1b[3m) must be emitted, and the comment palette color
    // (muted #586e75 = 88,110,117) must precede the comment text.
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
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try std.testing.expectError(
        error.QueryUnavailable,
        hl.writeHighlightedBlock(allocator, &buf.writer, "const x = 1;", .zig, theme.syntaxPalette(.solarized_dark)),
    );
}

test "Highlighter: .failed is sticky across repeated calls" {
    var hl = Highlighter.init();
    defer hl.deinit();
    hl.forceLanguageFailedForTesting(.zig);

    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    // Repeated calls must keep returning QueryUnavailable — no retry, no
    // silent recovery — and the state must remain `.failed`.
    for (0..3) |_| {
        try std.testing.expectError(
            error.QueryUnavailable,
            hl.writeHighlightedBlock(allocator, &buf.writer, "x", .zig, theme.syntaxPalette(.solarized_dark)),
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

    // forceLanguageFailedForTesting must destroy the in-flight query so there
    // are no leaks reported by the testing allocator.
    hl.forceLanguageFailedForTesting(.zig);
    switch (hl.languages[Language.zig.index()]) {
        .failed => {},
        else => return error.TestExpectedFailedState,
    }
}
