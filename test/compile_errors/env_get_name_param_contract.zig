const env_like = @import("env_like");

const BadEnv = struct {
    pub fn get(_: []const u16) ?[]const u8 {
        return null;
    }
};

comptime {
    env_like.requireGetContract(BadEnv);
}
