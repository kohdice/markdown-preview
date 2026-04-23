const ansi = @import("ansi");

const BadEnv = struct {};

comptime {
    _ = ansi.detectColorMode(BadEnv);
}
