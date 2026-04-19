const std = @import("std");
const markdown_preview = @import("markdown_preview");
const parse = markdown_preview.parse;
const render = markdown_preview.render;
const source_loader = markdown_preview.source_loader;
const bench = @import("bench_support.zig");
const fixtures = @import("fixtures");

const AmbiguousWidth = markdown_preview.term.width.AmbiguousWidth;

const Fixture = struct {
    name: []const u8,
    spec: fixtures.Spec,
    ambiguous: AmbiguousWidth,
};

const Run = struct {
    read_ns: u64,
    parse_ns: u64,
    render_ns: u64,
    input_bytes: usize,
    output_bytes: usize,
    parse_counts: bench.CounterSnapshot,
    render_counts: bench.CounterSnapshot,
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const table = [_]Fixture{
        .{ .name = "small-8KiB-ascii", .spec = fixtures.small_ascii, .ambiguous = .narrow },
        .{ .name = "mid-128KiB-cjk", .spec = fixtures.mid_cjk, .ambiguous = .wide },
        .{ .name = "large-external", .spec = fixtures.large_external, .ambiguous = .narrow },
    };

    var explicit_ambiguous: ?AmbiguousWidth = null;
    var custom_path: ?[]const u8 = null;
    var skip_large = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--wide")) {
            explicit_ambiguous = .wide;
        } else if (std.mem.eql(u8, arg, "--narrow")) {
            explicit_ambiguous = .narrow;
        } else if (std.mem.eql(u8, arg, "--skip-large")) {
            skip_large = true;
        } else {
            custom_path = arg;
        }
    }

    if (custom_path) |path| {
        const ambiguous = explicit_ambiguous orelse blk: {
            for (table) |f| {
                if (std.mem.eql(u8, f.spec.path, path)) break :blk f.ambiguous;
            }
            std.debug.print("warning: ambiguous mode not specified for {s}; defaulting to narrow. Pass --wide for CJK-heavy input.\n", .{path});
            break :blk .narrow;
        };
        std.debug.print("pipeline benchmark (single fixture: {s}, ambiguous={s})\n", .{ path, @tagName(ambiguous) });
        const run = try runOnce(allocator, path, ambiguous);
        printRun("custom", run);
        return;
    }

    std.debug.print("pipeline benchmark (file -> parse -> render -> Discarding)\n", .{});
    for (table) |f| {
        fixtures.ensure(allocator, f.spec) catch |err| switch (err) {
            error.MissingFixture => {
                if (skip_large) {
                    std.debug.print("{s}: skipped (--skip-large, missing {s})\n", .{ f.name, f.spec.path });
                    continue;
                }
                return err;
            },
            else => return err,
        };
        const cold = try runOnce(allocator, f.spec.path, f.ambiguous);
        const warm = try runOnce(allocator, f.spec.path, f.ambiguous);
        printFixtureRuns(f.name, cold, warm);
    }
}

fn printRun(name: []const u8, run: Run) void {
    const kib = @as(f64, @floatFromInt(run.input_bytes)) / 1024.0;
    std.debug.print(
        "{s}: in={d:.1}KiB  read={d:.3}ms  parse={d:.3}ms  render={d:.3}ms  parse_allocs={d}  render_allocs={d}  out={d}B\n",
        .{
            name,
            kib,
            nsToMs(run.read_ns),
            nsToMs(run.parse_ns),
            nsToMs(run.render_ns),
            run.parse_counts.alloc_count,
            run.render_counts.alloc_count,
            run.output_bytes,
        },
    );
}

fn printFixtureRuns(name: []const u8, cold: Run, warm: Run) void {
    const kib = @as(f64, @floatFromInt(cold.input_bytes)) / 1024.0;
    std.debug.print(
        "{s}: in={d:.1}KiB  cold(read={d:.3}ms parse={d:.3}ms render={d:.3}ms)  warm(read={d:.3}ms parse={d:.3}ms render={d:.3}ms)  parse_allocs={d}  render_allocs={d}  out={d}B\n",
        .{
            name,
            kib,
            nsToMs(cold.read_ns),
            nsToMs(cold.parse_ns),
            nsToMs(cold.render_ns),
            nsToMs(warm.read_ns),
            nsToMs(warm.parse_ns),
            nsToMs(warm.render_ns),
            cold.parse_counts.alloc_count,
            cold.render_counts.alloc_count,
            cold.output_bytes,
        },
    );
}

fn runOnce(
    allocator: std.mem.Allocator,
    path: []const u8,
    ambiguous: AmbiguousWidth,
) !Run {
    var read_timer = try std.time.Timer.start();
    const loaded = try source_loader.loadFile(allocator, std.fs.cwd(), path);
    const read_ns = read_timer.read();
    const input_bytes = loaded.bytes.len;

    var parse_counting = bench.CountingAllocator.init(allocator);
    const parse_before = parse_counting.snapshot();
    var parse_timer = try std.time.Timer.start();
    var doc = switch (loaded.storage) {
        .mapped => |m| try parse.parseMapped(parse_counting.allocator(), m),
        .owned => |o| try parse.parseOwned(parse_counting.allocator(), o),
    };
    const parse_ns = parse_timer.read();
    defer doc.deinit();
    const parse_after = parse_counting.snapshot();

    var render_counting = bench.CountingAllocator.init(allocator);
    var renderer: render.Renderer = undefined;
    renderer.init(render_counting.allocator(), .{ .ambiguous_width = ambiguous });
    defer renderer.deinit();

    var sink: [4096]u8 = undefined;
    var discarding: std.io.Writer.Discarding = .init(&sink);

    const render_before = render_counting.snapshot();
    var render_timer = try std.time.Timer.start();
    try renderer.render(&discarding.writer, &doc, null);
    try discarding.writer.flush();
    const render_ns = render_timer.read();
    const render_after = render_counting.snapshot();

    return .{
        .read_ns = read_ns,
        .parse_ns = parse_ns,
        .render_ns = render_ns,
        .input_bytes = input_bytes,
        .output_bytes = discarding.fullCount(),
        .parse_counts = bench.CounterSnapshot.diff(parse_after, parse_before),
        .render_counts = bench.CounterSnapshot.diff(render_after, render_before),
    };
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
