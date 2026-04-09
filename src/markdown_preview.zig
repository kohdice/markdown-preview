pub const cli = @import("cli.zig");

const render = @import("render.zig");

pub const RenderOptions = render.RenderOptions;
pub const AmbiguousWidth = @import("width.zig").AmbiguousWidth;

test {
    _ = @import("cli.zig");
    _ = @import("render.zig");
    _ = @import("highlight.zig");
    _ = @import("parse.zig");
    _ = @import("parse_document_test.zig");
    _ = @import("parse_table.zig");
    _ = @import("entity.zig");
    _ = @import("width.zig");
    _ = @import("terminal.zig");
}
