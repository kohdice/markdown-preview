const width = @import("width");

const BadEnv = struct {};

comptime {
    _ = width.detectAmbiguousWidth(BadEnv);
}
