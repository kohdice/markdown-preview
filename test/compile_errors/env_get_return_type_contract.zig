const env_like = @import("env_like");

const BadEnv = struct {
    pub fn get(_: []const u8) []const u8 {
        return "";
    }
};

comptime {
    env_like.requireGetContract(BadEnv);
}
