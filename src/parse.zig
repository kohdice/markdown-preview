const std = @import("std");
const ast = @import("ast.zig");
const block_phase = @import("parse/block_phase.zig");
const inline_phase = @import("parse/inline_phase.zig");
const parse_inline = @import("parse/inline.zig");
const source_mod = @import("source");

pub const Document = ast.Document;
pub const Source = source_mod.Source;

/// Raw-lines side channel for trigger-free paragraphs. The renderer walks
/// `blocks` in block-phase emission order and advances a cursor in this
/// slice; when the paragraph pointer matches the cursor's entry, it
/// renders the lines directly without ever materialising an inline chain.
/// The public `ast.Paragraph` stays `{ children = no_inline }` for these
/// blocks, so external consumers see a uniform semantic shape. Headings
/// always go through the full inline parser; benchmark evidence does not
/// justify extending this bypass to them.
pub const TrivialRun = struct {
    paragraph: *const ast.Paragraph,
    lines: Lines,

    /// Single-line entries store the line inline to avoid a per-entry slice
    /// header allocation; multi-line entries reuse the `paragraph_lines`
    /// dupe that block_phase already had to allocate for setext detection.
    pub const Lines = union(enum) {
        single: []const u8,
        multi: []const []const u8,
    };
};

pub const ParsedDocument = struct {
    document: Document,

    pub fn deinit(self: *ParsedDocument) void {
        self.document.deinit();
    }
};

/// Bundle emitted by `parse()` that the renderer consumes. The public AST
/// lives at `parsed.document`; `trivial_runs` is an internal render-only
/// side channel (paragraph pointer → raw lines for trigger-free paragraphs)
/// that exists solely to let the renderer skip materialising a text +
/// soft_break chain. External callers interested only in the AST should
/// access `parsed.document` and ignore `trivial_runs`.
pub const ParseOutput = struct {
    parsed: ParsedDocument,
    trivial_runs: []const TrivialRun = &.{},

    pub fn deinit(self: *ParseOutput) void {
        self.parsed.deinit();
    }
};

fn estimateInlineNodeCapacity(bytes: []const u8) usize {
    // Scale the reserve with block boundaries (`\n\n`), not total line
    // count: a boundary is a reasonable proxy for the number of
    // parseSlice / parseLines calls that reach the builder after the
    // trivial-bypass path has claimed trigger-free content. This keeps
    // single-paragraph inputs with many internal soft breaks from
    // pre-allocating builder slots the bypass would leave unused.
    const separator_count = std.mem.count(u8, bytes, "\n\n");
    if (separator_count < 256) return 0;
    return @min(separator_count, 8192);
}

pub fn parse(allocator: std.mem.Allocator, src: Source) !ParseOutput {
    switch (src) {
        .borrowed => |bytes| return buildDocument(allocator, bytes, .borrowed),
        .owned => |o| {
            errdefer o.allocator.free(o.buffer);
            return buildDocument(allocator, o.buffer, .{ .owned = o });
        },
        .mapped => |m| {
            errdefer std.posix.munmap(m.bytes);
            return buildDocument(allocator, m.bytes, .{ .mapped = m });
        },
    }
}

fn buildDocument(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    storage: ast.Document.SourceStorage,
) !ParseOutput {
    const has_trailing_newline = bytes.len > 0 and bytes[bytes.len - 1] == '\n';

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var builder = parse_inline.InlineBuilder.init(arena.allocator());
    try builder.reserve(estimateInlineNodeCapacity(bytes));
    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), &builder, bytes);
    const resolved = try inline_phase.resolveInlines(arena.allocator(), &builder, block_doc);
    return .{
        .parsed = .{
            .document = .{
                .source = bytes,
                .source_storage = storage,
                .inline_nodes = resolved.inline_nodes,
                .inline_next = resolved.inline_next,
                .blocks = resolved.blocks,
                .link_defs = resolved.link_defs,
                .has_trailing_newline = has_trailing_newline,
                .storage = .{ .arena = arena },
            },
        },
        .trivial_runs = resolved.trivial_runs,
    };
}

test {
    _ = @import("parse/block_cursor.zig");
    _ = @import("parse/block_phase.zig");
    _ = @import("parse/document_test.zig");
    _ = @import("parse/inline_phase.zig");
    _ = @import("parse/inline_trigger.zig");
    _ = @import("parse/inline_work.zig");
    _ = @import("parse/lifecycle_test.zig");
}

test "parse builds a document for a single paragraph" {
    var output = try parse(std.testing.allocator, .{ .borrowed = "Hello\n" });
    defer output.deinit();

    try std.testing.expectEqual(@as(usize, 1), output.parsed.document.blocks.len);
    try std.testing.expect(output.parsed.document.has_trailing_newline);
}
