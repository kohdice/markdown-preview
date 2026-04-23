const std = @import("std");

pub const cache_dir = ".bench-cache";

const ascii_example_path = "examples/EXAMPLE.md";
const cjk_example_path = "examples/EXAMPLE_ja.md";
const repeated_doc_separator = "\n\n---\n\n";

pub const Spec = struct {
    path: []const u8,
    target_bytes: usize,
    seed_path: []const u8,
};

pub const sample_ascii: Spec = .{
    .path = cache_dir ++ "/sample-ascii.md",
    .target_bytes = 8 * 1024,
    .seed_path = ascii_example_path,
};

pub const sample_cjk: Spec = .{
    .path = cache_dir ++ "/sample-cjk.md",
    .target_bytes = 8 * 1024,
    .seed_path = cjk_example_path,
};

pub const stress_ascii: Spec = .{
    .path = cache_dir ++ "/stress-ascii.md",
    .target_bytes = 1024 * 1024,
    .seed_path = ascii_example_path,
};

pub const stress_cjk: Spec = .{
    .path = cache_dir ++ "/stress-cjk.md",
    .target_bytes = 1024 * 1024,
    .seed_path = cjk_example_path,
};

pub fn ensure(allocator: std.mem.Allocator, io: std.Io, spec: Spec) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, cache_dir);

    const expected = try makeExampleFixture(allocator, io, spec.target_bytes, spec.seed_path);
    defer allocator.free(expected);

    if (cwd.readFileAlloc(io, spec.path, allocator, .limited(1 << 28))) |actual| {
        defer allocator.free(actual);
        if (std.mem.eql(u8, actual, expected)) return;
    } else |_| {}

    var file = try cwd.createFile(io, spec.path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, expected);
}

fn makeExampleFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    approx_size: usize,
    seed_path: []const u8,
) anyerror![]u8 {
    const cwd = std.Io.Dir.cwd();
    const seed = try cwd.readFileAlloc(io, seed_path, allocator, .limited(1 << 20));
    defer allocator.free(seed);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, seed);
    if (approx_size <= seed.len) return out.toOwnedSlice(allocator);

    while (out.items.len + repeated_doc_separator.len + seed.len <= approx_size) {
        try out.appendSlice(allocator, repeated_doc_separator);
        try out.appendSlice(allocator, seed);
    }

    return out.toOwnedSlice(allocator);
}

test "makeExampleFixture uses the English example document as the sample fixture seed" {
    const expected = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        ascii_example_path,
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(expected);

    const fixture = try makeExampleFixture(
        std.testing.allocator,
        std.testing.io,
        sample_ascii.target_bytes,
        sample_ascii.seed_path,
    );
    defer std.testing.allocator.free(fixture);

    try std.testing.expectEqualStrings(expected, fixture);
}

test "makeExampleFixture uses the Japanese example document as the sample fixture seed" {
    const expected = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        cjk_example_path,
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(expected);

    const fixture = try makeExampleFixture(
        std.testing.allocator,
        std.testing.io,
        sample_cjk.target_bytes,
        sample_cjk.seed_path,
    );
    defer std.testing.allocator.free(fixture);

    try std.testing.expectEqualStrings(expected, fixture);
}

test "makeExampleFixture repeats the Japanese example document without truncating sections" {
    const expected = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        cjk_example_path,
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(expected);

    const target = expected.len * 3;
    const fixture = try makeExampleFixture(std.testing.allocator, std.testing.io, target, cjk_example_path);
    defer std.testing.allocator.free(fixture);

    try std.testing.expect(std.mem.startsWith(u8, fixture, expected));
    try std.testing.expect(std.mem.count(u8, fixture, "## 終了行") >= 2);
    try std.testing.expect(std.mem.count(u8, fixture, "```mermaid") >= 2);
}
