const std = @import("std");
const fixtures_mod = @import("fixtures");

const mp_flag = "--mp=";

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mp_path: ?[]const u8 = null;
    var skip_large = false;
    var positional = std.ArrayListUnmanaged([]const u8).empty;
    defer positional.deinit(allocator);

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, mp_flag)) {
            mp_path = arg[mp_flag.len..];
        } else if (std.mem.eql(u8, arg, "--skip-large")) {
            skip_large = true;
        } else {
            try positional.append(allocator, arg);
        }
    }

    const mp_binary = mp_path orelse {
        std.debug.print("error: missing --mp=<path>; build.zig must pin the release binary.\n", .{});
        return error.MissingMpPath;
    };
    if (!exists(mp_binary)) {
        std.debug.print("error: {s} not found.\n", .{mp_binary});
        return error.MissingBinary;
    }

    try ensureHyperfine(allocator);

    var default_fixtures: std.ArrayListUnmanaged([]const u8) = .empty;
    defer default_fixtures.deinit(allocator);

    if (positional.items.len == 0) {
        for (fixtures_mod.all) |spec| {
            fixtures_mod.ensure(allocator, spec) catch |err| switch (err) {
                error.MissingFixture => {
                    if (skip_large) {
                        std.debug.print("skipping {s}: --skip-large\n", .{spec.path});
                        continue;
                    }
                    return err;
                },
                else => return err,
            };
            try default_fixtures.append(allocator, spec.path);
        }
    }

    const fixtures: []const []const u8 = if (positional.items.len > 0)
        positional.items
    else
        default_fixtures.items;

    for (fixtures) |path| {
        if (!exists(path)) {
            std.debug.print("{s}: missing\n", .{path});
            continue;
        }
        try runHyperfine(allocator, mp_binary, path);
    }
}

fn ensureHyperfine(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&.{ "hyperfine", "--version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const ok = blk: {
        child.spawn() catch break :blk false;
        const term = child.wait() catch break :blk false;
        switch (term) {
            .Exited => |code| break :blk code == 0,
            else => break :blk false,
        }
    };
    if (!ok) {
        std.debug.print(
            "error: hyperfine not found on PATH. Install it (e.g. `brew install hyperfine`) and retry.\n",
            .{},
        );
        return error.HyperfineMissing;
    }
}

fn runHyperfine(
    allocator: std.mem.Allocator,
    mp_binary: []const u8,
    path: []const u8,
) !void {
    const cat_cmd = try std.fmt.allocPrint(allocator, "cat {s} > /dev/null", .{path});
    defer allocator.free(cat_cmd);
    const mp_cmd = try std.fmt.allocPrint(allocator, "{s} {s} > /dev/null", .{ mp_binary, path });
    defer allocator.free(mp_cmd);

    std.debug.print("\n=== {s} ===\n", .{path});

    var child = std.process.Child.init(&.{
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
    }, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("hyperfine exited with status {d} for {s}\n", .{ code, path });
            return error.HyperfineFailed;
        },
        else => {
            std.debug.print("hyperfine terminated abnormally for {s}\n", .{path});
            return error.HyperfineFailed;
        },
    }
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
