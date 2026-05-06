const std = @import("std");
const mermaid_source = @import("source.zig");
const parse_class = @import("parse_class.zig");
const parse_er = @import("parse_er.zig");
const parse_flowchart = @import("parse_flowchart.zig");
const parse_git = @import("parse_git.zig");
const parse_sequence = @import("parse_sequence.zig");
const parse_state = @import("parse_state.zig");
const parse_xychart = @import("parse_xychart.zig");

fn expectParserAcceptsSourceForms(comptime parser: type, source: []const u8) !void {
    const alloc = std.testing.allocator;

    var from_bytes = try parser.parse(alloc, source);
    defer from_bytes.deinit();

    var from_borrowed = try parser.parse(alloc, mermaid_source.Source{ .borrowed = source });
    defer from_borrowed.deinit();

    const owned = try alloc.dupe(u8, source);
    var from_owned = try parser.parse(alloc, mermaid_source.Source{ .owned = owned });
    defer from_owned.deinit();
}

test "shared mermaid source normalization keeps sequence parse results for borrowed and raw bytes" {
    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: hi
    ;

    var from_bytes = try parse_sequence.parse(std.testing.allocator, source);
    defer from_bytes.deinit();

    var from_borrowed = try parse_sequence.parse(std.testing.allocator, mermaid_source.Source{ .borrowed = source });
    defer from_borrowed.deinit();

    try std.testing.expectEqual(@as(usize, 2), from_bytes.participants.len);
    try std.testing.expectEqual(from_bytes.participants.len, from_borrowed.participants.len);
    try std.testing.expectEqual(from_bytes.messages.len, from_borrowed.messages.len);
    try std.testing.expectEqualStrings(from_bytes.participants[0].label, from_borrowed.participants[0].label);
    try std.testing.expectEqualStrings(from_bytes.participants[1].label, from_borrowed.participants[1].label);
    try std.testing.expectEqualStrings(from_bytes.messages[0].label, from_borrowed.messages[0].label);
}

test "shared mermaid source normalization preserves Source.owned buffer for sequence parser" {
    const alloc = std.testing.allocator;
    const owned = try alloc.dupe(u8,
        \\sequenceDiagram
        \\    Alice->>Bob: hi
    );

    var diagram = try parse_sequence.parse(alloc, mermaid_source.Source{ .owned = owned });
    defer diagram.deinit();

    try std.testing.expect(diagram.owned_strings.len > 0);
    try std.testing.expectEqual(@intFromPtr(owned.ptr), @intFromPtr(diagram.owned_strings[0].ptr));
}

test "all mermaid parsers accept raw, borrowed, and owned source forms" {
    try expectParserAcceptsSourceForms(parse_flowchart,
        \\graph TD
        \\    A --> B
    );
    try expectParserAcceptsSourceForms(parse_sequence,
        \\sequenceDiagram
        \\    Alice->>Bob: hi
    );
    try expectParserAcceptsSourceForms(parse_class,
        \\classDiagram
        \\    class Animal
    );
    try expectParserAcceptsSourceForms(parse_state,
        \\stateDiagram-v2
        \\    [*] --> Idle
    );
    try expectParserAcceptsSourceForms(parse_er,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    try expectParserAcceptsSourceForms(parse_git,
        \\gitGraph:
        \\    commit
    );
    try expectParserAcceptsSourceForms(parse_xychart,
        \\xychart
        \\    bar [1, 2]
    );
}
