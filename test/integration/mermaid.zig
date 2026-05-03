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

    try renderer.render(&output.writer, doc, wrap_width);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

fn expectMermaidSectionsRespectWidth(
    allocator: std.mem.Allocator,
    sections: []const mermaid_helpers.MarkdownMermaidSection,
    wrap_width: usize,
    allowlist: []const mermaid_helpers.MermaidDiagnosticAllowlistEntry,
) !void {
    for (sections) |section| {
        try mermaid_helpers.expectNoUnexpectedDiagnostic(allocator, section, wrap_width, allowlist);
        try mermaid_helpers.expectNoGeneratedClipping(section.source, section.body);
        try mermaid_helpers.expectBodyRowsFit(section.body, wrap_width, .narrow);
    }
}

test "mixed Markdown Mermaid renderers fit width 40 without diagnostics or clipping" {
    const allocator = std.testing.allocator;
    const source =
        \\# Mixed Mermaid fixture
        \\
        \\```mermaid
        \\flowchart TD
        \\    Start --> Work
        \\    Work --> Done
        \\```
        \\
        \\Between diagrams.
        \\
        \\```mermaid
        \\sequenceDiagram
        \\    participant User
        \\    participant API
        \\    User->>API: Login request
        \\    API-->>User: OK
        \\```
        \\
        \\```mermaid
        \\classDiagram
        \\    class User {
        \\        +int id
        \\        +email str
        \\    }
        \\```
        \\
        \\```mermaid
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Active : start
        \\    Active --> [*]
        \\```
        \\
        \\```mermaid
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\```
        \\
        \\```mermaid
        \\gitGraph
        \\    commit id: "init"
        \\    branch dev
        \\    commit tag: "work"
        \\    checkout main
        \\    merge dev tag: "done"
        \\```
        \\
        \\```mermaid
        \\xychart
        \\title "Sales"
        \\x-axis [Q1, Q2, Q3]
        \\y-axis 0 --> 100
        \\bar [30, 60, 40]
        \\line [20, 50, 70]
        \\```
        \\
        \\```mermaid
        \\xychart horizontal
        \\title "Revenue"
        \\x-axis [Jan, Feb, Mar]
        \\y-axis 0 --> 300
        \\bar [120, 200, 260]
        \\```
        \\
    ;
    const section_names = [_][]const u8{
        "mixed flowchart",
        "mixed sequence",
        "mixed class",
        "mixed state",
        "mixed ER",
        "mixed gitGraph",
        "mixed vertical xychart",
        "mixed horizontal xychart",
    };

    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .wrap_width = 40 });
    defer allocator.free(rendered);

    var sections = try mermaid_helpers.extractMarkdownMermaidSections(allocator, source, rendered, &section_names);
    defer sections.deinit();

    const allowlist = [_]mermaid_helpers.MermaidDiagnosticAllowlistEntry{};
    try expectMermaidSectionsRespectWidth(allocator, sections.sections, 40, &allowlist);
}

fn expectExampleMermaidSectionsRespectWidth(
    allocator: std.mem.Allocator,
    wrap_width: usize,
    allowlist: []const mermaid_helpers.MermaidDiagnosticAllowlistEntry,
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/EXAMPLE.md", allocator, .limited(1 << 20));
    defer allocator.free(source);

    const section_names = [_][]const u8{
        "example flowchart basic TD",
        "example flowchart basic LR",
        "example flowchart nested subgraph",
        "example sequence basic",
        "example sequence blocks and note",
        "example class basic",
        "example class namespace",
        "example state basic",
        "example state composite",
        "example ER",
        "example gitGraph",
        "example vertical xychart",
        "example horizontal xychart",
    };

    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .wrap_width = wrap_width });
    defer allocator.free(rendered);

    var sections = try mermaid_helpers.extractMarkdownMermaidSections(allocator, source, rendered, &section_names);
    defer sections.deinit();

    try expectMermaidSectionsRespectWidth(allocator, sections.sections, wrap_width, allowlist);
}

test "examples EXAMPLE.md Mermaid sections fit width 40 without unexpected diagnostics or clipping" {
    const allocator = std.testing.allocator;
    const allowlist = [_]mermaid_helpers.MermaidDiagnosticAllowlistEntry{};

    try expectExampleMermaidSectionsRespectWidth(allocator, 40, &allowlist);
}

test "examples EXAMPLE.md Mermaid sections fit width 80 without clipping" {
    const allocator = std.testing.allocator;
    const allowlist = [_]mermaid_helpers.MermaidDiagnosticAllowlistEntry{};

    try expectExampleMermaidSectionsRespectWidth(allocator, 80, &allowlist);
}

test "Mermaid placeholder paths wrap fallback body at constrained width" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected_diagnostic: []const u8,
        expected_source_fragment: []const u8,
    }{
        .{
            .source =
            \\gantt
            \\    title demo
            \\    section setup
            \\    first task :a, 2026-05-02, 1d
            ,
            .expected_diagnostic = "[mermaid: diagram type not yet supported by mp]",
            .expected_source_fragment = "first task :a, 2026-05-02, 1d",
        },
        .{
            .source =
            \\notARealMermaidDiagram
            \\    Alpha --> Beta
            \\    Beta --> Gamma
            ,
            .expected_diagnostic = "[mermaid: parse error]",
            .expected_source_fragment = "notARealMermaidDiagram",
        },
    };

    for (cases) |case| {
        var fixture = try mermaid_helpers.renderFencedDiagram(allocator, case.source, .{ .wrap_width = 18 });
        defer fixture.deinit();

        try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, case.expected_diagnostic);
        try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, case.expected_source_fragment);
        try mermaid_helpers.expectNoGeneratedClipping(case.source, fixture.body);
        try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
    }
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
    try std.testing.expect(std.mem.find(u8, rendered, "\n```\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "A") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "B") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "▼") != null);
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
    try std.testing.expect(std.mem.find(u8, wide, "[mermaid:") == null);
    try std.testing.expect(std.mem.find(u8, wide, "A") != null);
    try std.testing.expect(std.mem.find(u8, wide, "B") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "yes") != null);
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
    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid: diagram type not yet supported by mp]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "gantt") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "task :a, 0, 3d") != null);
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
    try std.testing.expect(std.mem.find(u8, rendered, "CUSTOMER") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "ORDER") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "places") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid:") == null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "BRAND_MST") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "BRAND_DETAIL_MST") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid:") == null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "CUSTOMER") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "ORDER") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid:") == null);
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
    try std.testing.expect(std.mem.find(u8, rendered, "●") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[main]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[develop]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid:") == null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "cherry-pick") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "direction LR") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "gitGraph TB:") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid: feature not yet supported by mp]") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid:") == null);
    try std.testing.expect(std.mem.find(u8, rendered, "●") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[main]") != null);
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
    try std.testing.expect(std.mem.find(u8, rendered, "Alice") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Bob") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Hello") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Hi") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid:") == null);
}

test "sequenceDiagram null wrap width keeps simple ASCII snapshot byte-identical" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Bob-->>Alice: Hi
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .wrap_width = null });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\```mermaid
        \\┌───────┐         ┌───────┐
        \\│ Alice │         │  Bob  │
        \\└───┬───┘         └───┬───┘
        \\    │                 │
        \\    │      Hello      │
        \\    ├─────────────────►
        \\    │       Hi        │
        \\    ◄╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌│
        \\    │                 │
        \\┌───┴───┐         ┌───┴───┐
        \\│ Alice │         │  Bob  │
        \\└───────┘         └───────┘
        \\```
        \\
    , rendered);
}

test "sequenceDiagram null wrap width keeps block and note snapshot byte-identical" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    alt success
        \\        A->>B: ok
        \\    else failure
        \\        B-->>A: no
        \\    end
        \\    par one
        \\        A->>B: p1
        \\    and two
        \\        B->>A: p2
        \\    end
        \\    Note over A,B: shared
        \\```
        \\
    ;
    const rendered = try helpers.renderToOwnedSlice(allocator, source, .{ .wrap_width = null });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\```mermaid
        \\┌────┐                  ┌────┐
        \\│ A  │                  │ B  │
        \\└──┬─┘                  └──┬─┘
        \\   │                       │
        \\┌ alt [success]────────────┼─┐
        \\│  │          ok           │ │
        \\│  ├───────────────────────► │
        \\├ failure╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
        \\│  │          no           │ │
        \\│  ◄╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌│ │
        \\└──────────────────────────┴─┘
        \\┌ par [one]────────────────┬─┐
        \\│  │          p1           │ │
        \\│  ├───────────────────────► │
        \\├ two╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
        \\│  │          p2           │ │
        \\│  ◄───────────────────────┤ │
        \\│┌─┬───────────────────────┼┐│
        \\││ │        shared         │││
        \\│└─┴───────────────────────┴┘│
        \\└──┬───────────────────────┬─┘
        \\   │                       │
        \\┌──┴─┐                  ┌──┴─┐
        \\│ A  │                  │ B  │
        \\└────┘                  └────┘
        \\```
        \\
    , rendered);
}

test "sequenceDiagram positive wrap width too small uses terminal-width diagnostic" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 4 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(
        allocator,
        fixture.body,
        "[mermaid: terminal width too small to render diagram]",
    );
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid: parse error]");
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 4, .narrow);
}

test "sequenceDiagram wraps single participant label under wrap width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant Solo as This Participant Name Wraps Across Lines
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 10 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "This");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Particip");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "antName");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Name");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Wraps");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Across");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Lines");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 10, .narrow);
}

test "sequenceDiagram centers CJK participant label by display width under wrap width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant User as 利用者
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 10 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.find(u8, fixture.body, "│ 利用者 │") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 10, .narrow);
}

test "sequenceDiagram wraps long participant and message labels without generated clipping" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant Client as Very Long Client Participant
        \\    participant API as Very Long API Participant
        \\    Client->>API: request payload with many fields and validation details
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 24 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Very");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Client");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Partici");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "request");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "payload");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "validation");
    try std.testing.expect(std.mem.find(u8, fixture.body, "►") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "->>") == null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 24, .narrow);
}

test "sequenceDiagram at width eighty preserves three participants messages arrows and lifelines" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant Client
        \\    participant Gateway
        \\    participant Database
        \\    Client->>Gateway: submit order request
        \\    Gateway-->>Database: read inventory snapshot
        \\    Database-->>Client: return accepted response
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 80 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Client");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Gateway");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Database");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "submitorderrequest");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "readinventorysnapshot");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "returnacceptedresponse");
    try std.testing.expect(std.mem.find(u8, fixture.body, "►") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "◄") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "╌") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "->>") == null);
    try std.testing.expect(hasSequenceLifelineRow(fixture.body, 3, &.{ "Client", "Gateway", "Database" }));
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 80, .narrow);
}

test "sequenceDiagram preserves hard-break message labels under wrap width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    A->>B: first<br/>second<br>third<BR>fourth
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

test "sequenceDiagram wraps self messages while preserving display clusters and literal ellipsis" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant User as 利用者
        \\    User->>User: é ❤️ 👨‍👩 already … keep clusters together
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 16 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "利用者");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "é");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "\u{2764}\u{FE0F}");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "\u{1F468}\u{200D}\u{1F469}");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "alread");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "y…");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "keep");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cluste");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "togeth");
    try std.testing.expect(std.mem.find(u8, fixture.body, "◄") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 16, .narrow);
}

test "sequenceDiagram wraps later-column self messages without dropping label text" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    B->>B: aa bb cc dd ee ff gg hh ii jj
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "aa");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "bb");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cc");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "dd");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "ee");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "ff");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "gg");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "hh");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "ii");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "jj");
    try std.testing.expect(std.mem.find(u8, fixture.body, "◄") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "sequenceDiagram wraps right left and over notes under wrap width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    A->>B: go
        \\    Note right of A: right side note with several words
        \\    Note left of B: left side note with several words
        \\    Note over A: one participant note with several words
        \\    Note over A,B: two participant note with several words
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rightside");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "leftsidenote");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "oneparticipantnote");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "twoparticipant");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "severalwords");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "sequenceDiagram same-band edge note does not use cross-band continuation" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    A->>B: go
        \\    Note right of B: right edge note with several words
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rightedgenote");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "several");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "words");
    try std.testing.expect(std.mem.find(u8, fixture.body, "[cross-band]") == null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "sequenceDiagram wrapped edge notes inside blocks preserve block side borders" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    loop guarded block
        \\        A->>B: go
        \\        Note left of A: left edge note with several words
        \\        Note right of B: right edge note with several words
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "leftedgenote");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rightedgenote");
    try std.testing.expect(std.mem.find(u8, fixture.body, "│┌") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "┐│") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "sequenceDiagram wraps notes and block labels under wrap width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant Client
        \\    participant API
        \\    alt success branch with a long condition label
        \\        Client->>API: send request
        \\    else failed because timeout exceeded
        \\        API-->>Client: retry later
        \\    end
        \\    Note over Client,API: response metadata contains cache validators and rate limit hints
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 28 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "alt[successbranchwith");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "alongconditionlabel]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "failedbecausetimeout");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "exceeded");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "responsemetadata");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cache");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "validators");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rate");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "limithints");
    try std.testing.expect(std.mem.find(u8, fixture.body, "◄") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 28, .narrow);
}

test "sequenceDiagram preserves supported block kinds and divider labels under wrap width" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    loop every minute
        \\        A->>B: ping
        \\    end
        \\    opt optional branch
        \\        A->>B: maybe
        \\    end
        \\    par alpha branch
        \\        A->>B: p1
        \\    and beta branch
        \\        B->>A: p2
        \\    end
        \\    critical connect
        \\        A->>B: hello
        \\    option failure path
        \\        B-->>A: retry
        \\    end
        \\    rect highlighted area
        \\        A->>B: inside
        \\    end
        \\    break stop now
        \\        A->>B: stopped
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 26 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "loop[everyminute]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "opt[optionalbranch]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "par[alphabranch]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "betabranch");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "critical[connect]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "failurepath");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "rect[highlighted");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "area]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "break[stopnow]");
    try std.testing.expect(std.mem.find(u8, fixture.body, "◄") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 26, .narrow);
}

test "sequenceDiagram nested wrapped blocks keep continuous side-border prefixes" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant Client
        \\    participant API
        \\    loop outer condition label that wraps
        \\        alt inner branch label that wraps
        \\            Client->>API: wrapped message inside nested frame
        \\        else fallback branch label that wraps
        \\            API-->>Client: fallback message inside nested frame
        \\            Note over Client,API: wrapped note inside nested frame
        \\        end
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 28 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "loop[outercondition");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "labelthatwraps]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "alt[innerbranch");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "thatwraps");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "fallbackbranchlabel");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "thatwraps");
    try std.testing.expect(std.mem.find(u8, fixture.body, "┌") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "├") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "►") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "◄") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 28, .narrow);
}

test "sequenceDiagram emits participant bands and cross-band continuation rows" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    A->>B: same band
        \\    A-->>D: cross band response with a long label
        \\    Note over A,D: note spans bands too
        \\    A->>+D: activation parsed but not drawn
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "sameband");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cross-band");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "crossband");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "responsewithalong");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "label");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "notespansbandstoo");
    try std.testing.expect(std.mem.find(u8, fixture.body, "-->>") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "║") == null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "sequenceDiagram banded width sixty preserves labels without mermaid diagnostics" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    participant E
        \\    participant F
        \\    A->>B: same band request
        \\    C-->>E: same band response
        \\    A->>F: cross band request with enough text to wrap
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 60 });
    defer fixture.deinit();

    inline for (&.{ "A", "B", "C", "D", "E", "F" }) |label| {
        try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, label);
    }
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "sameband");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "request");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "samebandresponse");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cross-band");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "crossbandrequest");
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 60, .narrow);
}

test "sequenceDiagram cross-band continuations render in endpoint bands only" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    participant E
        \\    participant F
        \\    A->F: solid open endpoint message
        \\    F-->A: dashed open endpoint response
        \\    Note over A,F: endpoint note
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, fixture.body, "[cross-band] A"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, fixture.body, "[cross-band] F"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, fixture.body, "[cross-band] Note"));
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "A->F:solidopen");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "F-->A:dashedopen");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "endpointnote");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "sequenceDiagram blocks spanning participant bands preserve labels dividers and message order" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    participant E
        \\    loop cross band transaction
        \\        A->>E: first cross band request
        \\    else cross band fallback
        \\        B-->>D: second cross band response
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    const loop_pos = std.mem.find(u8, fixture.body, "loop") orelse return error.TestUnexpectedResult;
    const first_pos = std.mem.find(u8, fixture.body, "first") orelse return error.TestUnexpectedResult;
    const else_pos = std.mem.find(u8, fixture.body, "fallback") orelse return error.TestUnexpectedResult;
    const second_pos = std.mem.find(u8, fixture.body, "second") orelse return error.TestUnexpectedResult;

    try std.testing.expect(loop_pos < first_pos);
    try std.testing.expect(first_pos < else_pos);
    try std.testing.expect(else_pos < second_pos);
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "loop[crossband");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "transaction]");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "crossband");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "fallback");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "[cross-band]A");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "->>E:first");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "request");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "[cross-band]B");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "-->>D:second");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cross");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "response");
    try std.testing.expect(std.mem.find(u8, fixture.body, "[cross-band] A") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "->> E: first") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "[cross-band] B") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "-->> D: second") != null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "sequenceDiagram cross-band continuation rows preserve source message order in affected bands" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    participant C
        \\    participant D
        \\    C->>A: first from later band
        \\    A->>D: second from earlier band
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20 });
    defer fixture.deinit();

    const first_pos = std.mem.find(u8, fixture.body, "first") orelse return error.TestUnexpectedResult;
    const second_pos = std.mem.find(u8, fixture.body, "second") orelse return error.TestUnexpectedResult;

    try std.testing.expect(first_pos < second_pos);
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "[cross-band]C");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "->>A:first");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "[cross-band]A");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "->>D:second");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .narrow);
}

test "sequenceDiagram note over body rows clear lifelines from note interior" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    A->>B: go
        \\    Note over A,B: two participant note with several words
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    var saw_note_body = false;
    var rows = std.mem.splitScalar(u8, fixture.body, '\n');
    while (rows.next()) |row| {
        if (std.mem.find(u8, row, "words") == null) continue;
        saw_note_body = true;
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, row, "│"));
    }

    try std.testing.expect(saw_note_body);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "sequenceDiagram wrapped sequential blocks at same index are not nested" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    loop a
        \\    end
        \\    loop b
        \\        A->>B: x
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 30 });
    defer fixture.deinit();

    const a_pos = std.mem.find(u8, fixture.body, "loop [a]") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.find(u8, fixture.body, "loop [b]") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < b_pos);
    try std.testing.expect(std.mem.find(u8, fixture.body, "│┌") == null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 30, .narrow);
}

test "sequenceDiagram wrapped empty block after last message is preserved" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    A->>B: x
        \\    loop cleanup
        \\    end
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 30 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "loop[cleanup]");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 30, .narrow);
}

test "sequenceDiagram wrapped renderer fits ambiguous-wide rows" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\sequenceDiagram
        \\    A->>B: hello wide mode
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 20, .ambiguous_width = .wide });
    defer fixture.deinit();

    try std.testing.expect(std.mem.find(u8, fixture.body, "+") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, ">") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "─") == null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "│") == null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "►") == null);
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 20, .wide);
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

    try std.testing.expect(std.mem.find(u8, rendered, "[mermaid: parse error]") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "not a real diagram") != null);
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
    try std.testing.expect(std.mem.find(u8, fixture.body, "gantt") != null);
    try std.testing.expect(std.mem.find(u8, fixture.body, "epsilon") != null);
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
    try std.testing.expect(std.mem.find(u8, fixture.body, "several") != null);
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

    try std.testing.expect(std.mem.find(u8, fixture.body, "[mermaid: terminal width too small to render diagram]") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "─") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "│") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "+") == null);
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

    try std.testing.expect(std.mem.find(u8, narrow, "αβγ") != null);
    try std.testing.expect(std.mem.find(u8, wide, "αβγ") != null);

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

fn hasSequenceLifelineRow(body: []const u8, min_lifelines: usize, participant_labels: []const []const u8) bool {
    var rows = std.mem.splitScalar(u8, body, '\n');
    while (rows.next()) |row| {
        if (std.mem.find(u8, row, "┌") != null) continue;
        if (std.mem.find(u8, row, "┐") != null) continue;
        if (std.mem.find(u8, row, "└") != null) continue;
        if (std.mem.find(u8, row, "┘") != null) continue;

        var has_label = false;
        for (participant_labels) |label| {
            if (std.mem.find(u8, row, label) != null) {
                has_label = true;
                break;
            }
        }
        if (has_label) continue;

        if (std.mem.count(u8, row, "│") >= min_lifelines) return true;
    }
    return false;
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

    try std.testing.expect(std.mem.find(u8, rendered, "►") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "╱") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "╲") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Check") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "日本語") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "►") != null);
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

test "constrained classDiagram wraps a single long member inside the class box" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    class Customer {
        \\        +string veryVeryVeryLongMemberName
        \\    }
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 18 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Customer");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "+");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "veryVeryVeryLo");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "ngMemberName:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "string");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
}

test "constrained classDiagram reflows same-level classes into additional rows" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    class Alpha
        \\    class Beta
        \\    class Gamma
        \\    class Delta
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 18 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Alpha");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Beta");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Gamma");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Delta");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
}

test "constrained classDiagram preserves wrapped relationship label after layout" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    Customer --> Order : places a very long relation label
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Customer");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Order");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "places a");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "very long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "relation");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "label");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "constrained classDiagram preserves long relationship label between narrow boxes" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    A --> B : very very very very long label
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

test "constrained classDiagram preserves wrapped cardinality labels" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    Customer "one very long side" --> "many very long orders" Order : has
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 26 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Customer");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Order");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "has");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "one very");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "long side");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "many very");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "long orders");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 26, .narrow);
}

test "constrained classDiagram namespace grows vertically around wrapped members" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    namespace Shapes {
        \\        class VeryLongCircleClass {
        \\            +string centerCoordinateName
        \\        }
        \\        class VeryLongSquareClass {
        \\            +string cornerCoordinateName
        \\        }
        \\    }
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 22 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Shapes");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "VeryLongCircle");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Class");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "centerCoordina");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "teName: string");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "VeryLongSquare");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "cornerCoordina");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 22, .narrow);
}

test "constrained classDiagram wraps long namespace title" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    namespace VeryLongNamespaceNameForShapes {
        \\        class Circle
        \\    }
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .wrap_width = 18 });
    defer fixture.deinit();

    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "VeryLong");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "mespace");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Nam");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "eFor");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Shapes");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Circle");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 18, .narrow);
}

test "constrained classDiagram ANSI spans preserve display clusters in wrapped members" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\classDiagram
        \\    class Cafe {
        \\        +string éValue$
        \\        +draw❤️‍🔥()*
        \\        +string 顧客識別子
        \\    }
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .enable_ansi = true, .wrap_width = 16 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.find(u8, fixture.rendered, "\x1b[4m") != null);
    try std.testing.expect(std.mem.find(u8, fixture.rendered, "\x1b[3m") != null);
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "éValue:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "draw❤️‍🔥(): *");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "顧客識別子:");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 16, .narrow);
}

test "constrained gitGraph bands commits and preserves merge text at width 40" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\gitGraph
        \\    commit id: "root … é"
        \\    branch 開発ブランチ長い
        \\    commit tag: "dev❤️‍🔥tag"
        \\    commit type: HIGHLIGHT tag: "highlight-long-tag"
        \\    checkout main
        \\    commit type: REVERSE tag: "reverse-very-long"
        \\    commit
        \\    commit
        \\    commit
        \\    commit
        \\    merge 開発ブランチ長い tag: "merge label"
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .enable_ansi = true, .wrap_width = 40 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.find(u8, fixture.rendered, "\x1b[38;2;") != null);
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "root … é");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "dev❤️‍🔥tag");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "開発ブランチ長い");
    try mermaid_helpers.expectBodyContainsSubsequenceIgnoringWhitespace(allocator, fixture.body, "highlight-long-tag");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "reverse-very-long");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "merge 開発ブランチ長い -> main: merge label");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "■");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "⊗");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "◎");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 40, .narrow);
}

test "constrained vertical xychart scales plot and wraps labels at width 40" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\xychart
        \\title "Revenue trend é❤️‍🔥 long title"
        \\x-axis "Quarter labels with long words" [AlphaBetaGammaDelta, 顧客識別子, "literal … marker"]
        \\y-axis "Sales amount"
        \\bar [10, 35, 20]
        \\line [12, 20, 30]
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .enable_ansi = true, .wrap_width = 40 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.find(u8, fixture.rendered, "\x1b[38;2;") != null);
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Revenue trend é❤️‍🔥 long title");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Quarter labels with long words");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Sales amount");
    try mermaid_helpers.expectBodyContainsSubsequenceIgnoringWhitespace(allocator, fixture.body, "AlphaBetaGammaDelta");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "顧客識別子");
    try mermaid_helpers.expectBodyContainsSubsequenceIgnoringWhitespace(allocator, fixture.body, "literal … marker");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Bar 1");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Line 1");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "█");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 40, .narrow);
}

test "constrained horizontal xychart wraps category column and scales plot at width 40" {
    const allocator = std.testing.allocator;
    const mermaid_source =
        \\xychart horizontal
        \\title "Horizontal é❤️‍🔥 chart"
        \\x-axis "Category axis title" [AlphaBetaGammaDelta, 顧客識別子, "literal … marker"]
        \\y-axis "Value axis title" 0 --> 100
        \\bar [20, 70, 40]
        \\line [10, 55, 90]
    ;
    var fixture = try mermaid_helpers.renderFencedDiagram(allocator, mermaid_source, .{ .enable_ansi = true, .wrap_width = 40 });
    defer fixture.deinit();

    try std.testing.expect(std.mem.find(u8, fixture.rendered, "\x1b[38;2;") != null);
    try mermaid_helpers.expectBodyLacksIgnoringWhitespace(allocator, fixture.body, "[mermaid:");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Horizontal é❤️‍🔥 chart");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Category axis title");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Value axis title");
    try mermaid_helpers.expectBodyContainsSubsequenceIgnoringWhitespace(allocator, fixture.body, "AlphaBetaGammaDelta");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "顧客識別子");
    try mermaid_helpers.expectBodyContainsSubsequenceIgnoringWhitespace(allocator, fixture.body, "literal … marker");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Bar 1");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "Line 1");
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, fixture.body, "█");
    try mermaid_helpers.expectNoGeneratedClipping(mermaid_source, fixture.body);
    try mermaid_helpers.expectBodyRowsFit(fixture.body, 40, .narrow);
}

test "constrained gitGraph and xychart use width-too-small diagnostics when unreadable" {
    const allocator = std.testing.allocator;
    const git_source =
        \\gitGraph
        \\    commit
    ;
    var git_fixture = try mermaid_helpers.renderFencedDiagram(allocator, git_source, .{ .wrap_width = 7 });
    defer git_fixture.deinit();
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, git_fixture.body, "[mermaid: terminal width too small to render diagram]");
    try mermaid_helpers.expectBodyRowsFit(git_fixture.body, 7, .narrow);

    const xy_source =
        \\xychart
        \\bar [1]
    ;
    var xy_fixture = try mermaid_helpers.renderFencedDiagram(allocator, xy_source, .{ .wrap_width = 7 });
    defer xy_fixture.deinit();
    try mermaid_helpers.expectBodyContainsIgnoringWhitespace(allocator, xy_fixture.body, "[mermaid: terminal width too small to render diagram]");
    try mermaid_helpers.expectBodyRowsFit(xy_fixture.body, 7, .narrow);
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

    try std.testing.expect(std.mem.find(u8, rendered, "A") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "●") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "[main]") != null);
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

    try std.testing.expect(std.mem.find(u8, rendered, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Demo") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "█") != null);
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
