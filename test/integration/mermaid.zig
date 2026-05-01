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
    try canvas.drawLabel(0, 0, "abcdefghijklmnop", .narrow);

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

test "flowchart hard-break node labels render as centered multiline text" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\graph TD
        \\    A[first<br/>second<br>third<BR>fourth] --> B
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 18 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "first");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "second");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "third");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "fourth");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
}

test "flowchart overlong node label wraps without generated clipping" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\graph LR
        \\    A[AlphaBetaGammaDelta] --> B
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 12 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "AlphaBet");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "aGammaDe");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "lta");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 12, .narrow);
}

test "constrained flowchart LR chain reflows into width-bounded bands" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    A --> B --> C --> D
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 8 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "A");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "B");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "C");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "D");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 8, .narrow);
}

test "constrained flowchart reports width too small instead of dropping band-crossing edges" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    A --> C
        \\    B --> C
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 8 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
        allocator,
        fixture.body,
        "[mermaid: terminal width too small to render diagram]",
    );
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "A --> C");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "B --> C");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 8, .narrow);
}

test "constrained graph RL chain keeps normalized LR parity" {
    const allocator = std.testing.allocator;
    var lr = try mermaid_helpers.renderFencedDiagram(allocator,
        \\graph LR
        \\    A --> B --> C
    , .{ .wrap_width = 8 });
    defer lr.deinit();
    var rl = try mermaid_helpers.renderFencedDiagram(allocator,
        \\graph RL
        \\    A --> B --> C
    , .{ .wrap_width = 8 });
    defer rl.deinit();

    try std.testing.expectEqualStrings(lr.body, rl.body);
    try mermaid_helpers.expectBodyRowsFit(rl.body, 8, .narrow);
}

test "constrained stateDiagram LR reflows without diagnostics" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\stateDiagram-v2
        \\    direction LR
        \\    [*] --> Idle
        \\    Idle --> Active : begin long transition
        \\    state Active {
        \\        [*] --> Working
        \\        Working --> [*] : done
        \\    }
        \\    Active --> [*] : finish
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Active");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Idle");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Working");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "begin");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "transitio");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "done");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "finish");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "●");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "top-down graph and state outputs stay unchanged when wrap width is wide" {
    const allocator = std.testing.allocator;

    const flowchart_source =
        \\flowchart TD
        \\    A -->|ready| B
        \\    B --> C
    ;
    var flowchart_null = try mermaid_helpers.renderFencedDiagram(allocator, flowchart_source, .{});
    defer flowchart_null.deinit();
    var flowchart_wide = try mermaid_helpers.renderFencedDiagram(allocator, flowchart_source, .{ .wrap_width = 80 });
    defer flowchart_wide.deinit();
    try std.testing.expectEqualStrings(flowchart_null.body, flowchart_wide.body);

    const state_source =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Working : request
        \\    Working --> [*]
    ;
    var state_null = try mermaid_helpers.renderFencedDiagram(allocator, state_source, .{});
    defer state_null.deinit();
    var state_wide = try mermaid_helpers.renderFencedDiagram(allocator, state_source, .{ .wrap_width = 80 });
    defer state_wide.deinit();
    try std.testing.expectEqualStrings(state_null.body, state_wide.body);
}

test "flowchart banding preserves route labels and edge styles" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    item_mst -->|current FK| sales_item_mst
        \\    sales_item_mst -->|split brand data| product_mst
        \\    product_mst -.-> brand_mst
        \\    brand_mst -->|rebuild from new tables| brand_detail_mst
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "item_mst");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "sales_item_mst");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "product_mst");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "brand_mst");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "brand_detail_mst");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "current FK");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "split brand data");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rebuild");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "from new");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "tables");
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try std.testing.expect(std.mem.find(u8, fixture.body, "╌") != null or std.mem.find(u8, fixture.body, "╎") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "flowchart banding keeps deferred route labels from overwriting nodes" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    A -->|long label overwrites route maybe| B
        \\    B --> C
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "A");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "B");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "C");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "long label");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "overwrites");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "route");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "maybe");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "horizontal flowchart wraps long route label without width diagnostic" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    A -->|AlphaBetaGammaDelta| B
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "AlphaBetaGammaDelta");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "horizontal flowchart uses planned wrap budget for canvas-width route labels" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    A -->|12345678901234567890| B
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try std.testing.expect(std.mem.find(u8, fixture.body, "12345678901234567890") == null);
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "12345678901234567890");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "horizontal flowchart bands when route label needs more rows than side padding" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart LR
        \\    A -->|one two three four five six seven eight nine ten eleven twelve| B
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "one two three four five six seven eight nine ten eleven twelve");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "design flowchart keeps adjacent route labels separated" {
    const allocator = std.testing.allocator;
    const mermaid_source = @embedFile("../fixtures/mermaid_design_flowchart.mmd");
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "current read");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "split");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "vintage");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "data");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rebuild");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "from new");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "tables");
    try std.testing.expect(std.mem.find(u8, fixture.body, "rebuildvintage") == null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "newdata") == null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "top-down flowchart wraps route labels that would otherwise be omitted" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart TD
        \\    A -->|AlphaBetaGammaDelta| B
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 12 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "A");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "B");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "AlphaB");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "etaGam");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "maDelt");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "a");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "▼");
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 12, .narrow);
}

test "top-down flowchart redraws deferred route labels with the planned wrap budget" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart TD
        \\    A -->|AlphaBetaGammaDeltaEpsilon| B
        \\    A --> C
        \\    A --> D
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 24 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try std.testing.expect(std.mem.find(u8, fixture.body, "AlphaBetaGammaDeltaEpsil") == null);
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "AlphaBetaGam");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "maDeltaEpsil");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "on");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 24, .narrow);
}

test "top-down flowchart preserves route labels that do not fit the selected path segment" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart TD
        \\    A -->|edge label| B
        \\    A --> C
        \\    A --> D
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 80 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "edge label");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 80, .narrow);
}

test "constrained flowchart subgraph title wraps without clipping" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart TD
        \\    subgraph Long Name
        \\        A --> B
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 14 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Name");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 14, .narrow);
}

test "constrained flowchart subgraph title grows vertically without widening the frame" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\flowchart TD
        \\    subgraph Very Very Very Very Long Name
        \\        A --> B
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 14 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try std.testing.expect(std.mem.count(u8, fixture.body, "Very") >= 4);
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Name");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 14, .narrow);
}

test "constrained erDiagram wraps single oversized attribute row without clipping" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\erDiagram
        \\    CUSTOMER {
        \\        string very_very_very_long_attribute_name PK
        \\    }
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 18 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "CUSTOMER");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "PK string");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "very_very_very");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "_long_attribut");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "e_name");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
}

test "constrained erDiagram wraps oversized entity name without dropping characters" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\erDiagram
        \\    VERY_LONG_CUSTOMER_ENTITY_NAME {
        \\        string id
        \\    }
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 18 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "VERY_LONG_CUST");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "OMER_ENTITY_NA");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "ME");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "string id");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
}

test "constrained erDiagram keeps wrapped relationship labels and crow markers" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places a very long relationship label
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "CUSTOMER");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "ORDER");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "places a");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "very long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "relationshi");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "p label");
    try std.testing.expect(std.mem.find(u8, fixture.body, "○") != null or
        std.mem.find(u8, fixture.body, "╤") != null or
        std.mem.find(u8, fixture.body, "╪") != null or
        std.mem.find(u8, fixture.body, "╫") != null or
        std.mem.find(u8, fixture.body, "╬") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "constrained erDiagram preserves long relationship label between narrow boxes" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\erDiagram
        \\    A ||--|| B : very very very very long label
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "A");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "B");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "very very very very long label");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
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
