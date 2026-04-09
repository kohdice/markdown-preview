const render = @import("render.zig");
const width = @import("width.zig");

pub const RenderOptions = render.RenderOptions;
pub const renderMarkdown = render.renderMarkdown;
pub const detectAmbiguousFromProcess = width.detectAmbiguousFromProcess;
pub const AmbiguousWidth = width.AmbiguousWidth;

test {
    _ = @import("cli.zig");
    _ = @import("render.zig");
    _ = @import("highlight.zig");
    _ = @import("parse_document.zig");
    _ = @import("parse_table.zig");
    _ = @import("entity.zig");
    _ = @import("width.zig");
}
