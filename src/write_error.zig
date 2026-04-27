const std = @import("std");

/// Surface the underlying syscall error (e.g. `BrokenPipe`, `NoSpaceLeft`)
/// instead of the generic `error.WriteFailed` that `std.Io.Writer`
/// propagates. Mirrors the `file_writer.err.?` pattern used across the Zig
/// 0.16 stdlib (see `std.Io.Dir.readFileAlloc` / file-copy implementations).
pub fn unwrapWriteError(
    err: anyerror,
    stdout_stream: *std.Io.File.Writer,
    stderr_stream: *std.Io.File.Writer,
) anyerror {
    if (err == error.WriteFailed) {
        if (stdout_stream.err) |underlying| return underlying;
        if (stderr_stream.err) |underlying| return underlying;
    }
    return err;
}

fn stubWriter(err: ?std.Io.File.Writer.Error) std.Io.File.Writer {
    return .{
        .io = undefined,
        .file = undefined,
        .err = err,
        .interface = undefined,
    };
}

test "unwrapWriteError surfaces stdout underlying error on WriteFailed" {
    var stdout = stubWriter(error.BrokenPipe);
    var stderr = stubWriter(null);
    const ret = unwrapWriteError(error.WriteFailed, &stdout, &stderr);
    try std.testing.expectEqual(@as(anyerror, error.BrokenPipe), ret);
}

test "unwrapWriteError falls back to stderr when stdout has no recorded err" {
    var stdout = stubWriter(null);
    var stderr = stubWriter(error.BrokenPipe);
    const ret = unwrapWriteError(error.WriteFailed, &stdout, &stderr);
    try std.testing.expectEqual(@as(anyerror, error.BrokenPipe), ret);
}

test "unwrapWriteError returns the original WriteFailed when neither stream recorded an err" {
    var stdout = stubWriter(null);
    var stderr = stubWriter(null);
    const ret = unwrapWriteError(error.WriteFailed, &stdout, &stderr);
    try std.testing.expectEqual(@as(anyerror, error.WriteFailed), ret);
}

test "unwrapWriteError returns the original err verbatim for non-WriteFailed" {
    var stdout = stubWriter(error.BrokenPipe);
    var stderr = stubWriter(error.BrokenPipe);
    const ret = unwrapWriteError(error.OutOfMemory, &stdout, &stderr);
    try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), ret);
}
