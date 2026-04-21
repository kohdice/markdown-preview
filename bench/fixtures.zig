const std = @import("std");

pub const cache_dir = ".bench-cache";

pub const Spec = struct {
    path: []const u8,
    target_bytes: usize,
    generator: *const fn (std.mem.Allocator, usize) anyerror![]u8,
};

pub const small_ascii: Spec = .{
    .path = cache_dir ++ "/small.md",
    .target_bytes = 8 * 1024,
    .generator = makeAsciiProse,
};

pub const mid_cjk: Spec = .{
    .path = cache_dir ++ "/mid.md",
    .target_bytes = 128 * 1024,
    .generator = makeCjkProse,
};

pub const all = [_]Spec{ small_ascii, mid_cjk };

pub fn ensure(allocator: std.mem.Allocator, io: std.Io, spec: Spec) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, cache_dir);

    const expected = try spec.generator(allocator, spec.target_bytes);
    defer allocator.free(expected);

    if (cwd.readFileAlloc(io, spec.path, allocator, .limited(1 << 28))) |actual| {
        defer allocator.free(actual);
        if (std.mem.eql(u8, actual, expected)) return;
    } else |_| {}

    var file = try cwd.createFile(io, spec.path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, expected);
}

pub fn ensureAll(allocator: std.mem.Allocator, io: std.Io) !void {
    for (all) |spec| try ensure(allocator, io, spec);
}

pub fn makeAsciiProse(allocator: std.mem.Allocator, approx_size: usize) anyerror![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    const paragraph =
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ++
        "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " ++
        "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris " ++
        "nisi ut aliquip ex ea commodo consequat.\n\n";

    const heading = "## Section heading with some text\n\n";
    const code_fence = "```zig\nconst x: u32 = 42;\nstd.debug.print(\"{}\\n\", .{x});\n```\n\n";
    const list_block = "- item one\n- item two\n- item three\n\n";

    try out.appendSlice(allocator, "# Document title\n\n");
    var written: usize = out.items.len;
    var cycle: u8 = 0;
    while (written < approx_size) : (cycle +%= 1) {
        const block: []const u8 = switch (cycle % 4) {
            0 => paragraph,
            1 => list_block,
            2 => heading,
            else => code_fence,
        };
        try out.appendSlice(allocator, block);
        written = out.items.len;
    }

    return out.toOwnedSlice(allocator);
}

pub fn makeCjkProse(allocator: std.mem.Allocator, approx_size: usize) anyerror![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    const paragraph_ja =
        "これはマークダウンレンダラのベンチマーク用に用意した日本語段落です。" ++
        "Markdown の解析とレンダリングを同時に計測することで、" ++
        "East Asian Width の判定や ambiguous 幅の扱いが全体性能に与える影響を見ます。\n\n";

    const heading_ja = "## 見出しに混ざる English mix セクション\n\n";
    const list_ja = "- リスト項目その一\n- リスト項目その二 with ASCII tail\n- 項目3 — 長めの続き\n\n";
    const quote_ja = "> 引用ブロックの内側にも日本語が入ります。Pipeline 計測対象。\n\n";

    try out.appendSlice(allocator, "# 日本語ドキュメント\n\n");
    var written: usize = out.items.len;
    var cycle: u8 = 0;
    while (written < approx_size) : (cycle +%= 1) {
        const block: []const u8 = switch (cycle % 4) {
            0 => paragraph_ja,
            1 => list_ja,
            2 => heading_ja,
            else => quote_ja,
        };
        try out.appendSlice(allocator, block);
        written = out.items.len;
    }

    return out.toOwnedSlice(allocator);
}
