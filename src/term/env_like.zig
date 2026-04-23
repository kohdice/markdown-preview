const std = @import("std");

pub const contract_message = "env-like type must provide get(name: []const u8) ?[]const u8";
pub const missing_get_diagnostic_tag = "[env_like_missing_get]";
pub const invalid_get_receiver_diagnostic_tag = "[env_like_invalid_get_receiver]";
pub const invalid_get_name_param_diagnostic_tag = "[env_like_invalid_get_name_param]";
pub const invalid_get_return_type_diagnostic_tag = "[env_like_invalid_get_return_type]";

fn missingGetError(comptime Container: type) noreturn {
    @compileError(contract_message ++ " (missing get on " ++ @typeName(Container) ++ ") " ++ missing_get_diagnostic_tag);
}

fn invalidGetReceiverError(comptime Container: type) noreturn {
    @compileError(std.fmt.comptimePrint(
        "{s} ({s}.get first parameter must be {s}, *{s}, or *const {s}) {s}",
        .{
            contract_message,
            @typeName(Container),
            @typeName(Container),
            @typeName(Container),
            @typeName(Container),
            invalid_get_receiver_diagnostic_tag,
        },
    ));
}

fn contractContainerType(comptime Env: type) type {
    return switch (@typeInfo(Env)) {
        .pointer => |pointer| contractContainerType(pointer.child),
        .@"struct", .@"enum", .@"union", .@"opaque" => Env,
        else => @compileError(contract_message ++ " (expected a container type or pointer to one, found " ++ @typeName(Env) ++ ")"),
    };
}

fn validateGetReceiver(comptime Container: type, comptime fn_info: std.builtin.Type.Fn) void {
    if (fn_info.params.len == 1) return;

    const receiver_type = fn_info.params[0].type orelse {
        @compileError(contract_message ++ " (" ++ @typeName(Container) ++ ".get must use a concrete receiver type)");
    };

    if (receiver_type != Container and receiver_type != *Container and receiver_type != *const Container) {
        invalidGetReceiverError(Container);
    }
}

pub fn requireGetContract(comptime Env: type) void {
    const Container = contractContainerType(Env);

    if (!@hasDecl(Container, "get")) {
        missingGetError(Container);
    }

    const get_info = @typeInfo(@TypeOf(Container.get));
    if (get_info != .@"fn") {
        @compileError(contract_message ++ " (" ++ @typeName(Container) ++ ".get is not a function)");
    }

    const fn_info = get_info.@"fn";
    if (fn_info.params.len < 1 or fn_info.params.len > 2) {
        @compileError(contract_message ++ " (" ++ @typeName(Container) ++ ".get has the wrong arity)");
    }
    validateGetReceiver(Container, fn_info);

    const name_param = fn_info.params[fn_info.params.len - 1].type orelse {
        @compileError(
            contract_message ++
                " (" ++ @typeName(Container) ++ ".get must use a concrete []const u8 parameter type) " ++
                invalid_get_name_param_diagnostic_tag,
        );
    };
    if (name_param != []const u8) {
        @compileError(
            contract_message ++
                " (" ++ @typeName(Container) ++ ".get last parameter must be []const u8) " ++
                invalid_get_name_param_diagnostic_tag,
        );
    }

    const return_type = fn_info.return_type orelse {
        @compileError(
            contract_message ++
                " (" ++ @typeName(Container) ++ ".get must return ?[]const u8) " ++
                invalid_get_return_type_diagnostic_tag,
        );
    };
    if (return_type != ?[]const u8) {
        @compileError(
            contract_message ++
                " (" ++ @typeName(Container) ++ ".get must return ?[]const u8) " ++
                invalid_get_return_type_diagnostic_tag,
        );
    }
}

pub fn StubEnv(comptime pairs: anytype) type {
    return struct {
        pub fn get(name: []const u8) ?[]const u8 {
            inline for (pairs) |pair| {
                if (std.mem.eql(u8, name, pair[0])) return pair[1];
            }
            return null;
        }
    };
}

test "requireGetContract accepts pointer-to-container env types" {
    const PointerEnv = struct {
        value: ?[]const u8 = "ok",

        pub fn get(self: @This(), name: []const u8) ?[]const u8 {
            _ = name;
            return self.value;
        }
    };

    comptime requireGetContract(*PointerEnv);
}

test "requireGetContract accepts const-pointer receiver env types" {
    const PointerReceiverEnv = struct {
        pub fn get(self: *const @This(), name: []const u8) ?[]const u8 {
            _ = self;
            _ = name;
            return null;
        }
    };

    comptime requireGetContract(PointerReceiverEnv);
}
