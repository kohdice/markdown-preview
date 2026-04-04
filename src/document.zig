const std = @import("std");

pub const max_file_bytes = 10 * 1024 * 1024;

pub fn readFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) ![]u8 {
    return dir.readFileAlloc(allocator, path, max_file_bytes);
}

pub fn trimCarriageReturn(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

test "trimCarriageReturn removes CR from CRLF lines" {
    try std.testing.expectEqualStrings("hello", trimCarriageReturn("hello\r"));
    try std.testing.expectEqualStrings("hello", trimCarriageReturn("hello"));
}
