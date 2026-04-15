pub const types = @import("mermaid/types.zig");
pub const canvas = @import("mermaid/canvas.zig");
pub const parse_flowchart = @import("mermaid/parse_flowchart.zig");
pub const layout_flowchart = @import("mermaid/layout_flowchart.zig");
pub const route = @import("mermaid/route.zig");
pub const parse_sequence = @import("mermaid/parse_sequence.zig");
pub const render_sequence = @import("mermaid/render_sequence.zig");
pub const parse_class = @import("mermaid/parse_class.zig");
pub const render_class = @import("mermaid/render_class.zig");
pub const parse_state = @import("mermaid/parse_state.zig");
pub const parse_er = @import("mermaid/parse_er.zig");
pub const render_er = @import("mermaid/render_er.zig");
pub const parse_git = @import("mermaid/parse_git.zig");
pub const render_git = @import("mermaid/render_git.zig");
pub const render = @import("mermaid/render.zig");

pub const RenderError = render.RenderError;
pub const Options = render.Options;
pub const writeMermaid = render.writeMermaid;

test {
    _ = @import("mermaid/types.zig");
    _ = @import("mermaid/canvas.zig");
    _ = @import("mermaid/parse_flowchart.zig");
    _ = @import("mermaid/layout_flowchart.zig");
    _ = @import("mermaid/route.zig");
    _ = @import("mermaid/parse_sequence.zig");
    _ = @import("mermaid/render_sequence.zig");
    _ = @import("mermaid/parse_class.zig");
    _ = @import("mermaid/render_class.zig");
    _ = @import("mermaid/parse_state.zig");
    _ = @import("mermaid/parse_er.zig");
    _ = @import("mermaid/render_er.zig");
    _ = @import("mermaid/parse_git.zig");
    _ = @import("mermaid/render_git.zig");
    _ = @import("mermaid/render.zig");
}
