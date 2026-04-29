const compile_mod = @import("mermaid/compile.zig");
const paint_mod = @import("mermaid/paint.zig");

pub const compile = compile_mod.compile;
pub const paint = paint_mod.paint;

pub const Diagram = compile_mod.Diagram;
pub const CompileError = compile_mod.CompileError;
pub const PaintError = paint_mod.PaintError;
pub const PaintOptions = paint_mod.PaintOptions;

test {
    _ = @import("mermaid/types.zig");
    _ = @import("mermaid/label.zig");
    _ = @import("mermaid/text_layout.zig");
    _ = @import("mermaid/canvas.zig");
    _ = @import("mermaid/parse_flowchart.zig");
    _ = @import("mermaid/layout_flowchart.zig");
    _ = @import("mermaid/route.zig");
    _ = @import("mermaid/parse_sequence.zig");
    _ = @import("mermaid/paint_sequence.zig");
    _ = @import("mermaid/parse_class.zig");
    _ = @import("mermaid/paint_class.zig");
    _ = @import("mermaid/parse_state.zig");
    _ = @import("mermaid/parse_er.zig");
    _ = @import("mermaid/paint_er.zig");
    _ = @import("mermaid/parse_git.zig");
    _ = @import("mermaid/paint_git.zig");
    _ = @import("mermaid/parse_xychart.zig");
    _ = @import("mermaid/paint_xychart.zig");
    _ = @import("mermaid/parse_source_test.zig");
    _ = @import("mermaid/directive.zig");
    _ = @import("mermaid/paint_flowchart.zig");
    _ = @import("mermaid/compile.zig");
    _ = @import("mermaid/paint.zig");
}
