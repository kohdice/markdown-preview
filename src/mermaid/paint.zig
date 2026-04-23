const std = @import("std");
const compile_mod = @import("compile.zig");
const paint_class = @import("paint_class.zig");
const paint_er = @import("paint_er.zig");
const paint_flowchart = @import("paint_flowchart.zig");
const paint_git = @import("paint_git.zig");
const paint_sequence = @import("paint_sequence.zig");
const paint_xychart = @import("paint_xychart.zig");
const ansi_mod = @import("../term/ansi.zig");
const width_mod = @import("../term/width.zig");

pub const PaintError = error{
    InvalidMermaid,
    UnsupportedDiagram,
    UnsupportedFeature,
    OutOfMemory,
    WriteFailed,
};

pub const PaintOptions = struct {
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
    color_mode: ansi_mod.ColorMode = .truecolor,
};

pub fn paint(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    diagram: *const compile_mod.Diagram,
    opts: PaintOptions,
) PaintError!void {
    return switch (diagram.*) {
        .flowchart => |*d| paint_flowchart.paintMermaidGraph(writer, allocator, d, opts),
        .state => |*d| paint_flowchart.paintMermaidGraph(writer, allocator, d, opts),
        .sequence => |*d| paint_sequence.paintSequence(writer, allocator, d, .{
            .wrap_width = opts.wrap_width,
            .ambiguous_width = opts.ambiguous_width,
        }) catch |err| mapRenderError(err),
        .class_ => |*d| paint_class.paintClass(writer, allocator, d, .{
            .wrap_width = opts.wrap_width,
            .ambiguous_width = opts.ambiguous_width,
            .enable_ansi = opts.enable_ansi,
            .color_mode = opts.color_mode,
        }) catch |err| mapRenderError(err),
        .er => |*d| paint_er.paintEr(writer, allocator, d, .{
            .wrap_width = opts.wrap_width,
            .ambiguous_width = opts.ambiguous_width,
        }) catch |err| mapRenderError(err),
        .git_graph => |*d| paint_git.paintGit(writer, allocator, d, .{
            .wrap_width = opts.wrap_width,
            .ambiguous_width = opts.ambiguous_width,
            .enable_ansi = opts.enable_ansi,
            .color_mode = opts.color_mode,
        }) catch |err| mapRenderError(err),
        .xychart => |*d| paint_xychart.paintXyChart(writer, allocator, d, .{
            .wrap_width = opts.wrap_width,
            .ambiguous_width = opts.ambiguous_width,
            .enable_ansi = opts.enable_ansi,
            .color_mode = opts.color_mode,
        }) catch |err| mapRenderError(err),
    };
}

fn mapRenderError(err: anyerror) PaintError {
    return switch (err) {
        error.InvalidMermaid => error.InvalidMermaid,
        error.UnsupportedFeature => error.UnsupportedFeature,
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed => error.WriteFailed,
        else => error.InvalidMermaid,
    };
}

fn expectPaintProducesOutput(source: []const u8, opts: PaintOptions) !void {
    const alloc = std.testing.allocator;

    var diagram = try compile_mod.compile(alloc, source);
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paint(&sink.writer, alloc, &diagram, opts);

    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "paint flowchart produces non-empty output" {
    const opts: PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try expectPaintProducesOutput("graph TD\n    A --> B\n", opts);
}

test "paint sequence produces non-empty output" {
    const opts: PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try expectPaintProducesOutput("sequenceDiagram\n    Alice->>Bob: hi\n", opts);
}

test "paint xychart produces non-empty output" {
    const opts: PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try expectPaintProducesOutput("xychart\nbar [1, 2, 3]\n", opts);
}

test "compile then paint accepts bare xychart source end-to-end" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\nbar [1, 2, 3]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });
    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "compile strips multi-line init directive before flowchart and paint renders" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\%%{init: {
        \\  "theme": "dark"
        \\}}%%
        \\graph TD
        \\    A --> B
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▼") != null);
}

test "compile+paint keeps %%{...}%% inside sequence message label" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\sequenceDiagram
        \\    Alice->>Bob: %%{x}%%
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "%%{x}%%") != null);
}

test "compile+paint keeps %%{...}%% inside flowchart node label" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\graph TD
        \\    A[%%{x}%%] --> B
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "%%{x}%%") != null);
}

test "compile silently strips init config scoped to a different diagram" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\%%{init: { "flowchart": { "curve": "basis" } }}%%
        \\sequenceDiagram
        \\    Alice->>Bob: hi
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hi") != null);
}

test "compile rejects init with diagram-specific config as UnsupportedFeature" {
    try std.testing.expectError(error.UnsupportedFeature, compile_mod.compile(
        std.testing.allocator,
        "%%{init: { \"gitGraph\": { \"mainBranchName\": \"trunk\" } }}%%\ngitGraph\n    commit\n",
    ));
}

test "compile rejects init xyChart config as UnsupportedFeature" {
    try std.testing.expectError(error.UnsupportedFeature, compile_mod.compile(
        std.testing.allocator,
        "%%{init: { \"xyChart\": { \"width\": 9999 } } }%%\nxychart\nbar [1, 2]\n",
    ));
}

test "compile+paint accepts init theme-only directive before xychart" {
    var diagram = try compile_mod.compile(
        std.testing.allocator,
        "%%{init: { \"theme\": \"dark\" }}%%\nxychart\nbar [1, 2]\n",
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "compile+paint treats lowercase xychart key as ordinary config (no UnsupportedFeature)" {
    var diagram = try compile_mod.compile(
        std.testing.allocator,
        "%%{init: { \"xychart\": { \"width\": 9999 } } }%%\nxychart\nbar [1, 2]\n",
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "compile returns UnsupportedDiagram for gantt" {
    try std.testing.expectError(error.UnsupportedDiagram, compile_mod.compile(std.testing.allocator, "gantt\n    title demo\n"));
}

test "graph BT output is canvas vertical flip of graph TD" {
    const alloc = std.testing.allocator;
    var td_diagram = try compile_mod.compile(alloc, "graph TD\n    A --> B --> C\n");
    defer td_diagram.deinit();
    var bt_diagram = try compile_mod.compile(alloc, "graph BT\n    A --> B --> C\n");
    defer bt_diagram.deinit();

    const opts: PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    var sink_td: std.Io.Writer.Allocating = .init(alloc);
    defer sink_td.deinit();
    var sink_bt: std.Io.Writer.Allocating = .init(alloc);
    defer sink_bt.deinit();

    try paint(&sink_td.writer, alloc, &td_diagram, opts);
    try paint(&sink_bt.writer, alloc, &bt_diagram, opts);

    const td_out = sink_td.writer.buffered();
    const bt_out = sink_bt.writer.buffered();

    const td_flipped = try flipOutputForTest(alloc, td_out);
    defer alloc.free(td_flipped);
    try std.testing.expectEqualStrings(td_flipped, bt_out);
}

fn flipOutputForTest(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |l| try lines.append(alloc, l);
    std.mem.reverse([]const u8, lines.items);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (lines.items, 0..) |line, i| {
        var view = std.unicode.Utf8View.init(line) catch return error.InvalidUtf8;
        var lit = view.iterator();
        while (lit.nextCodepoint()) |cp| {
            const mapped = testFlipGlyph(cp);
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(mapped, &enc) catch continue;
            try buf.appendSlice(alloc, enc[0..n]);
        }
        if (i + 1 < lines.items.len) try buf.append(alloc, '\n');
    }
    return try buf.toOwnedSlice(alloc);
}

fn testFlipGlyph(cp: u21) u21 {
    return switch (cp) {
        '┌' => '└',
        '└' => '┌',
        '┐' => '┘',
        '┘' => '┐',
        '┬' => '┴',
        '┴' => '┬',
        '▲' => '▼',
        '▼' => '▲',
        '╭' => '╰',
        '╰' => '╭',
        '╮' => '╯',
        '╯' => '╮',
        '╔' => '╚',
        '╚' => '╔',
        '╗' => '╝',
        '╝' => '╗',
        '╱' => '╲',
        '╲' => '╱',
        '^' => 'v',
        'v' => '^',
        '/' => '\\',
        '\\' => '/',
        else => cp,
    };
}

test "graph RL and graph LR produce identical output" {
    var lr_diagram = try compile_mod.compile(std.testing.allocator, "graph LR\n    A --> B --> C\n");
    defer lr_diagram.deinit();
    var rl_diagram = try compile_mod.compile(std.testing.allocator, "graph RL\n    A --> B --> C\n");
    defer rl_diagram.deinit();

    const opts: PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    var sink_lr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_lr.deinit();
    var sink_rl: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_rl.deinit();

    try paint(&sink_lr.writer, std.testing.allocator, &lr_diagram, opts);
    try paint(&sink_rl.writer, std.testing.allocator, &rl_diagram, opts);

    try std.testing.expectEqualStrings(sink_lr.writer.buffered(), sink_rl.writer.buffered());
}

test "paint draws frame and title around flowchart subgraph" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\graph TD
        \\    subgraph inner
        \\        A --> B
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "in") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B") != null);
}

test "paint drops edges to empty composite state" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Empty
        \\    state Empty {
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "├") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┤") == null);
}

test "paint draws composite state frame without routing to invisible node" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Outer
        \\    state Outer {
        \\        [*] --> Inner
        \\    }
        \\    Outer --> [*]
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Inner") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    const has_frame_boundary_tee =
        std.mem.indexOf(u8, out, "├") != null or
        std.mem.indexOf(u8, out, "┤") != null;
    try std.testing.expect(has_frame_boundary_tee);
}

test "paint renders erDiagram" {
    var diagram = try compile_mod.compile(std.testing.allocator, "erDiagram\n    CUSTOMER ||--o{ ORDER : places\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "places") != null);
}

test "paint renders gitGraph with LR colon header" {
    var diagram = try compile_mod.compile(std.testing.allocator, "gitGraph LR:\n    commit\n    commit\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[main]") != null);
}

test "compile returns UnsupportedFeature for cherry-pick" {
    try std.testing.expectError(error.UnsupportedFeature, compile_mod.compile(
        std.testing.allocator,
        "gitGraph\n    commit\n    cherry-pick id: \"a1\"\n",
    ));
}

test "compile returns UnsupportedFeature for erDiagram direction" {
    try std.testing.expectError(error.UnsupportedFeature, compile_mod.compile(
        std.testing.allocator,
        "erDiagram\n    direction LR\n    A ||--|| B : r\n",
    ));
}

test "paint renders stateDiagram-v2" {
    var diagram = try compile_mod.compile(std.testing.allocator, "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Running\n    Running --> [*]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Running") != null);
}

test "paint renders sequence diagram" {
    var diagram = try compile_mod.compile(std.testing.allocator, "sequenceDiagram\n    Alice->>Bob: hi\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hi") != null);
}

test "compile returns InvalidMermaid for unknown diagram type" {
    try std.testing.expectError(error.InvalidMermaid, compile_mod.compile(std.testing.allocator, "bogus\n"));
}

test "paint renders single-edge flowchart" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph TD\n    A --> B\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▼") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "┌") != null);
}

test "paint renders labeled edge with label text in output" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph TD\n    A --> B\n    B -->|yes| C\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "yes") != null);
}

test "paint keeps Unicode glyphs in wide ambiguous mode" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph TD\n    A --> B\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .wide,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+") == null);
}

test "paint LR direction renders horizontally" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph LR\n    A --> B\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "►") != null);
}

test "paint empty flowchart emits nothing" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph TD\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    try std.testing.expectEqualStrings("", sink.writer.buffered());
}

test "paint flowchart --- edge does not emit an arrow head" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph TD\n    A --- B\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▼") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▲") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
}

test "paint stateDiagram renders rounded corners for [*] and stadium states" {
    var diagram = try compile_mod.compile(std.testing.allocator, "stateDiagram-v2\n    [*] --> Idle\n    Idle --> [*]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╮") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╰") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╯") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Idle") != null);
}

test "paint diamond node renders with diamond corners" {
    var diagram = try compile_mod.compile(std.testing.allocator, "graph TD\n    A{Decide} --> B\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "╱") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╲") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Decide") != null);
}

test "paint dispatches xychart to paintXyChart" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\ntitle \"Demo\"\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "Demo") != null);
}

test "paint no longer returns UnsupportedDiagram for xychart" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paint(&sink.writer, std.testing.allocator, &diagram, .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });
}

test "compile still returns UnsupportedDiagram for unimplemented diagrams" {
    const headers = [_][]const u8{
        "gantt\n",
        "journey\n",
        "pie\n",
        "mindmap\n",
        "timeline\n",
        "quadrantChart\n",
        "sankey-beta\n",
        "block-beta\n",
    };
    for (headers) |h| {
        try std.testing.expectError(error.UnsupportedDiagram, compile_mod.compile(std.testing.allocator, h));
    }
}
