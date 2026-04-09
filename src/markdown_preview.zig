const cli = @import("cli.zig");
const width = @import("width.zig");

pub const run = cli.run;
pub const getTerminalWidth = cli.getTerminalWidth;
pub const unwrapWriteError = cli.unwrapWriteError;
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
