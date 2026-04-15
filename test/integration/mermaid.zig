const std = @import("std");
const helpers = @import("../helpers/render_from_source.zig");

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

test "init directive in gitGraph falls back to feature-not-supported diagnostic" {
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
