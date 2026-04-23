const width = @import("width");

const BadEnv = struct {
    pub fn get(_: usize, _: []const u8) ?[]const u8 {
        return null;
    }
};

comptime {
    const env: BadEnv = .{};
    _ = width.detectAmbiguousWidth(env);
}
