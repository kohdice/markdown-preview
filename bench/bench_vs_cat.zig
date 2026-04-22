const std = @import("std");
const fixtures_mod = @import("fixtures");

const mp_flag = "--mp=";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var mp_path: ?[]const u8 = null;
    var positional = std.ArrayListUnmanaged([]const u8).empty;
    defer positional.deinit(allocator);

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, mp_flag)) {
            mp_path = arg[mp_flag.len..];
        } else {
            try positional.append(allocator, arg);
        }
    }

    const mp_binary = mp_path orelse {
        std.debug.print("error: missing --mp=<path>; build.zig must pin the release binary.\n", .{});
        return error.MissingMpPath;
    };
    if (!exists(io, mp_binary)) {
        std.debug.print("error: {s} not found.\n", .{mp_binary});
        return error.MissingBinary;
    }

    try ensureHyperfine(io);

    var default_fixtures: std.ArrayListUnmanaged([]const u8) = .empty;
    defer default_fixtures.deinit(allocator);

    if (positional.items.len == 0) {
        for (fixtures_mod.all) |spec| {
            try fixtures_mod.ensure(allocator, io, spec);
            try default_fixtures.append(allocator, spec.path);
        }
    }

    const fixtures: []const []const u8 = if (positional.items.len > 0)
        positional.items
    else
        default_fixtures.items;

    for (fixtures) |path| {
        if (!exists(io, path)) {
            std.debug.print("{s}: missing\n", .{path});
            continue;
        }
        try runHyperfine(allocator, io, mp_binary, path);
    }
}

fn ensureHyperfine(io: std.Io) !void {
    const argv = [_][]const u8{ "hyperfine", "--version" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        std.debug.print(
            "error: hyperfine not found on PATH. Install it (e.g. `brew install hyperfine`) and retry.\n",
            .{},
        );
        return error.HyperfineMissing;
    };
    const term = child.wait(io) catch |err| {
        std.debug.print("error: hyperfine wait failed: {s}\n", .{@errorName(err)});
        return error.HyperfineMissing;
    };
    switch (term) {
        .exited => |code| if (code != 0) return error.HyperfineMissing,
        else => return error.HyperfineMissing,
    }
}

fn runHyperfine(
    allocator: std.mem.Allocator,
    io: std.Io,
    mp_binary: []const u8,
    path: []const u8,
) !void {
    const cat_cmd = try std.fmt.allocPrint(allocator, "cat {s} > /dev/null", .{path});
    defer allocator.free(cat_cmd);
    const mp_cmd = try std.fmt.allocPrint(allocator, "{s} {s} > /dev/null", .{ mp_binary, path });
    defer allocator.free(mp_cmd);

    std.debug.print("\n=== {s} ===\n", .{path});

    const argv = [_][]const u8{
        "hyperfine",
        "--warmup",
        "3",
        "--min-runs",
        "10",
        "--style",
        "basic",
        "--command-name",
        "cat",
        cat_cmd,
        "--command-name",
        "mp",
        mp_cmd,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("hyperfine exited with status {d} for {s}\n", .{ code, path });
            return error.HyperfineFailed;
        },
        else => {
            std.debug.print("hyperfine terminated abnormally for {s}\n", .{path});
            return error.HyperfineFailed;
        },
    }
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
