const ast = @import("../ast.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");

pub const RenderContext = struct {
    doc: *const ast.Document,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
};
