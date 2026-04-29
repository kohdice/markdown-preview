const std = @import("std");
const internals = @import("internals");
const parse = internals.parse;
const render = internals.render;
const helpers = @import("../helpers/render_from_source.zig");
const mermaid_helpers = @import("../helpers/mermaid_body.zig");
const canvas_mod = internals.mermaid_canvas;

fn renderDocumentWithRenderer(
    allocator: std.mem.Allocator,
    renderer: *render.Renderer,
    doc: *const parse.Document,
    wrap_width: ?usize,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(allocator);
    defer cycle_arena.deinit();

    try renderer.render(&output.writer, doc, wrap_width, cycle_arena.allocator());
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "mermaid fence renders diagram inside original backticks" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A --> B
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "```mermaid"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n```\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "▼") != null);
}

test "mermaid no-space edge A-->B produces the same output as spaced form" {
    const allocator = std.testing.allocator;
    const source_nospace =
        \\```mermaid
        \\graph TD
        \\    A-->B
        \\```
        \\
    ;
    const source_spaced =
        \\```mermaid
        \\graph TD
        \\    A --> B
        \\```
        \\
    ;
    const nospace = try helpers.renderToOwnedSlice(allocator, source_nospace, .{});
    defer allocator.free(nospace);
    const spaced = try helpers.renderToOwnedSlice(allocator, source_spaced, .{});
    defer allocator.free(spaced);

    try std.testing.expectEqualStrings(spaced, nospace);
}

test "width-only rerender reuses cached Mermaid diagrams" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A[AlphaBetaGammaDelta] --> B
        \\```
        \\
    ;

    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    var renderer = render.Renderer.init(allocator, .{});
    defer renderer.deinit();

    const wide = try renderDocumentWithRenderer(allocator, &renderer, &doc, 40);
    defer allocator.free(wide);
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_compile_count);

    const narrow = try renderDocumentWithRenderer(allocator, &renderer, &doc, 10);
    defer allocator.free(narrow);
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_compile_count);
    try std.testing.expect(wide.len > 0);
    try std.testing.expect(narrow.len > 0);
}

test "width-too-small Mermaid paint keeps compiled diagram cached for later wider render" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A --> B
        \\```
        \\
    ;

    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    var renderer = render.Renderer.init(allocator, .{});
    defer renderer.deinit();

    const narrow = try renderDocumentWithRenderer(allocator, &renderer, &doc, 1);
    defer allocator.free(narrow);
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
        allocator,
        narrow,
        "[mermaid: terminal width too small to render diagram]",
    );
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_compile_count);

    const wide = try renderDocumentWithRenderer(allocator, &renderer, &doc, 40);
    defer allocator.free(wide);
    try std.testing.expect(std.mem.indexOf(u8, wide, "[mermaid:") == null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "B") != null);
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_compile_count);
}

test "mermaid labeled edge renders the label text on the routed path" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A --> B
        \\    B -->|yes| C
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "yes") != null);
}

test "mermaid labeled edge with space before pipe matches the no-space form" {
    const allocator = std.testing.allocator;
    const spaced =
        \\```mermaid
        \\graph TD
        \\    A --> |yes| B
        \\```
        \\
    ;
    const nospace =
        \\```mermaid
        \\graph TD
        \\    A -->|yes| B
        \\```
        \\
    ;
    const a = try helpers.renderToOwnedSlice(allocator, spaced, .{});
    defer allocator.free(a);
    const b = try helpers.renderToOwnedSlice(allocator, nospace, .{});
    defer allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "unsupported diagram type emits diagnostic inside the fence followed by raw source" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\gantt
        \\    title demo
        \\    section s
        \\    task :a, 0, 3d
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "```mermaid"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid: diagram type not yet supported by mp]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "gantt") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "task :a, 0, 3d") != null);
}

test "erDiagram is rendered as ASCII art" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "```mermaid"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "places") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid:") == null);
}

test "erDiagram renders right-side zero-or-one marker o|" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\erDiagram
        \\    BRAND_MST ||--o| BRAND_DETAIL_MST : extends
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "BRAND_MST") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "BRAND_DETAIL_MST") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid:") == null);
}

test "erDiagram wraps wide same-level entities to the render width" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\erDiagram
        \\    A
        \\    B
        \\    C
        \\    D
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .wrap_width = 14 });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.find(u8, rendered, "\u{2026}") == null);
    try std.testing.expect(std.mem.find(u8, rendered, "A") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "B") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "C") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "D") != null);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(internals.term.width.displayWidth(line, .narrow) <= 14);
    }
}

test "erDiagram standalone entity renders the box" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\erDiagram
        \\    CUSTOMER
        \\    ORDER {}
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid:") == null);
}

test "gitGraph is rendered as ASCII art" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    commit
        \\    merge develop
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "```mermaid"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[main]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[develop]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid:") == null);
}

test "gitGraph cherry-pick falls back to feature-not-supported diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\gitGraph
        \\    commit
        \\    cherry-pick id: "a1"
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cherry-pick") != null);
}

test "erDiagram direction falls back to feature-not-supported diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\erDiagram
        \\    direction LR
        \\    A ||--|| B : r
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "direction LR") != null);
}

test "gitGraph TB orientation falls back to feature-not-supported diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\gitGraph TB:
        \\    commit
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "gitGraph TB:") != null);
}

test "init directive with gitGraph config falls back to feature-not-supported diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\%%{init: { "gitGraph": { "mainBranchName": "trunk" } }}%%
        \\gitGraph
        \\    commit
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
}

test "theme-only init directive renders gitGraph successfully" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\%%{init: { "theme": "dark" }}%%
        \\gitGraph
        \\    commit
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[main]") != null);
}

test "sequenceDiagram is rendered as ASCII art" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Bob-->>Alice: Hi
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "```mermaid"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid:") == null);
}

test "invalid mermaid emits parse-error diagnostic with raw source" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\not a real diagram
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mermaid: parse error]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "not a real diagram") != null);
}

test "mermaid body width helper ignores unchanged fence opener width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\gantt
        \\    title alpha beta gamma delta
        \\    section one
        \\    task one :a, 0, 1d
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 1 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.startsWith(u8, fixture.plain, "```mermaid"));
    try std.testing.expect(internals.term.width.displayWidth("```mermaid", .narrow) > 1);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 1, .narrow);
}

test "no-generated-clipping helper catches clipped canvas output" {
    var canvas = try canvas_mod.Canvas.init(std.testing.allocator, 1, 16);
    defer canvas.deinit();
    canvas.drawLabel(0, 0, "abcdefghijklmnop", .narrow);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try canvas_mod.writeCanvas(&sink.writer, &canvas, 5, .narrow);

    try std.testing.expectError(
        error.TestUnexpectedResult,
        mermaid_helpers.expectNoGeneratedClipping("graph TD\n    A --> B\n", sink.writer.buffered()),
    );
}

test "no-generated-clipping helper allows source literal ellipsis" {
    try mermaid_helpers.expectNoGeneratedClipping("graph TD\n    A[already …]\n", "already …");
}

test "no-generated-clipping helper catches extra ellipsis with source literal ellipsis" {
    try std.testing.expectError(
        error.TestUnexpectedResult,
        mermaid_helpers.expectNoGeneratedClipping("graph TD\n    A[already …]\n", "already …\nclipped …"),
    );
}

test "paint-level width too small uses terminal-width diagnostic instead of parse error" {
    const allocator = std.testing.allocator;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator,
        \\graph TD
        \\    A --> B
    , .{ .wrap_width = 1 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
        allocator,
        fixture.body,
        "[mermaid: terminal width too small to render diagram]",
    );
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid: parse error]");
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 1, .narrow);
}

test "renderer-local width too small reaches terminal-width diagnostic" {
    const allocator = std.testing.allocator;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator,
        \\erDiagram
        \\    CUSTOMER
    , .{ .wrap_width = 2 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
        allocator,
        fixture.body,
        "[mermaid: terminal width too small to render diagram]",
    );
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid: parse error]");
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 2, .narrow);
}

test "unsupported mermaid fallback wraps diagnostic and source body rows" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\gantt
        \\    title alpha beta gamma delta epsilon zeta
        \\    section one
        \\    task one :a, 0, 1d
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 12 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
        allocator,
        fixture.body,
        "[mermaid: diagram type not yet supported by mp]",
    );
    try std.testing.expect(std.mem.indexOf(u8, fixture.body, "gantt") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.body, "epsilon") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 12, .narrow);
}

test "unknown mermaid fallback wraps parse diagnostic and source body rows" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\unknownDiagram alpha beta gamma delta epsilon zeta
        \\    long source line with several words to wrap
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 10 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "[mermaid: parse error]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "unknownDiagram");
    try std.testing.expect(std.mem.indexOf(u8, fixture.body, "several") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 10, .narrow);
}

test "implemented mermaid width zero uses width-too-small route without zero-width cap" {
    const allocator = std.testing.allocator;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator,
        \\graph TD
        \\    A --> B
    , .{ .wrap_width = 0 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.indexOf(u8, fixture.body, "[mermaid: terminal width too small to render diagram]") != null);
    try std.testing.expect(internals.term.width.displayWidth(fixture.body, .narrow) > 0);
}

test "every implemented mermaid target uses width-too-small fallback at width one" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "graph TD\n    A --> B",
        "stateDiagram-v2\n    [*] --> Idle",
        "sequenceDiagram\n    Alice->>Bob: hi",
        "classDiagram\n    class Animal",
        "erDiagram\n    CUSTOMER",
        "gitGraph\n    commit",
        "xychart\n    bar [1, 2, 3]",
    };

    for (cases) |mermaid_source| {
        var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 1 });
        defer fixture.deinit();

        try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
            allocator,
            fixture.body,
            "[mermaid: terminal width too small to render diagram]",
        );
        try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
        try mermaid_helpers.expectBodyRowsFit(fixture.body, 1, .narrow);
    }
}

test "non-mermaid code fences are byte-identical to their input" {
    const allocator = std.testing.allocator;
    const source =
        \\```python
        \\print('hello')
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}

test "ambiguous_width wide keeps Unicode glyphs matching tables" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A --> B
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "+") == null);
}

test "ambiguous_width shifts box width for EAW=A labels (Greek)" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A[αβγ] --> B
        \\```
        \\
    ;
    const narrow = try helpers.renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .narrow });
    defer allocator.free(narrow);
    const wide = try helpers.renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(wide);

    try std.testing.expect(std.mem.indexOf(u8, narrow, "αβγ") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "αβγ") != null);

    try std.testing.expect(maxLineWidth(wide) > maxLineWidth(narrow));
}

fn maxLineWidth(text: []const u8) usize {
    var max: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len > max) max = line.len;
    }
    return max;
}

test "mermaid LR direction renders horizontally with right arrow" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph LR
        \\    A --> B
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "►") != null);
}

test "mermaid diamond decision node renders with diamond glyphs" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A{Check} --> B
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "╱") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "╲") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Check") != null);
}

test "mermaid CJK label preserves integrity and invariant" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph LR
        \\    A[日本語] --> B
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "日本語") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "►") != null);
}

test "mermaid self-loop does not hang" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\graph TD
        \\    A --> A
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "A") != null);
}

test "mermaid empty content renders empty fence" {
    const allocator = std.testing.allocator;
    const source = "```mermaid\n```\n";
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```mermaid\n```\n", rendered);
}

test "gitGraph with enable_ansi=true emits ANSI SGR through renderer pipeline" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .enable_ansi = true });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[main]") != null);
}

test "gitGraph enable_ansi=false matches bare-default call byte-for-byte" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop
        \\```
        \\
    ;
    const with_flag = try helpers.renderToOwnedSlice(allocator, source, .{ .enable_ansi = false });
    defer allocator.free(with_flag);
    const defaults = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(defaults);

    try std.testing.expectEqualStrings(with_flag, defaults);
}

test "xychart with enable_ansi=true emits ANSI SGR through renderer pipeline" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\xychart
        \\    title "Demo"
        \\    x-axis [a, b, c]
        \\    bar [1, 2, 3]
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .enable_ansi = true });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "█") != null);
}

test "xychart enable_ansi=false matches bare-default call byte-for-byte" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\xychart
        \\    title "Demo"
        \\    x-axis [a, b, c]
        \\    bar [1, 2, 3]
        \\```
        \\
    ;
    const with_flag = try helpers.renderToOwnedSlice(allocator, source, .{ .enable_ansi = false });
    defer allocator.free(with_flag);
    const defaults = try helpers.renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(defaults);

    try std.testing.expectEqualStrings(with_flag, defaults);
}
