pub const Theme = @import("theme.zig").Theme;
pub const AmbiguousWidth = @import("width.zig").AmbiguousWidth;
pub const RenderOptions = @import("render.zig").RenderOptions;
pub const renderMarkdown = @import("render.zig").renderMarkdown;

test {
    _ = @import("render.zig");
    _ = @import("highlight.zig");
    _ = @import("parse_document.zig");
}
