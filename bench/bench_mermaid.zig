const std = @import("std");
const bench = @import("bench_support.zig");
const mermaid = @import("mermaid");

const CompileResult = struct {
    elapsed_ns: u64,
    counts: bench.CounterSnapshot,
};

const PaintResult = struct {
    elapsed_ns: u64,
    counts: bench.CounterSnapshot,
    output_bytes: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("mermaid benchmark\n", .{});

    const flowchart_src = try makeFlowchartSource(allocator, 16);
    try runCompile("flowchart-compile-16", flowchart_src);
    try runPaint("flowchart-paint-16", flowchart_src);

    try runCompile("sequence-compile-small", sequence_sample);
    try runCompile("class-compile-small", class_sample);
    try runCompile("er-compile-small", er_sample);

    try runPaint("gitgraph-paint-small", gitgraph_sample);
    try runPaint("xychart-paint-small", xychart_sample);
}

fn runCompile(name: []const u8, source: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const allocator = counting.allocator();

    const cold = try compileOnce(allocator, source, &counting);
    const warm = try compileOnce(allocator, source, &counting);

    std.debug.print(
        "{s}: cold_compile={d:.3}ms cold_allocs={d} cold_bytes={d} warm_compile={d:.3}ms warm_allocs={d} warm_bytes={d}\n",
        .{
            name,
            nsToMs(cold.elapsed_ns),
            cold.counts.alloc_count,
            cold.counts.bytes_allocated,
            nsToMs(warm.elapsed_ns),
            warm.counts.alloc_count,
            warm.counts.bytes_allocated,
        },
    );
}

fn compileOnce(
    allocator: std.mem.Allocator,
    source: []const u8,
    counting: *const bench.CountingAllocator,
) !CompileResult {
    const before = counting.snapshot();
    var timer = try std.time.Timer.start();
    var diagram = try mermaid.compile(allocator, source);
    const elapsed_ns = timer.read();
    const after = counting.snapshot();

    diagram.deinit();

    return .{
        .elapsed_ns = elapsed_ns,
        .counts = bench.CounterSnapshot.diff(after, before),
    };
}

fn runPaint(name: []const u8, source: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const allocator = counting.allocator();

    var diagram = try mermaid.compile(allocator, source);
    defer diagram.deinit();

    const opts: mermaid.PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    const cold = try paintOnce(allocator, &diagram, opts, &counting);
    const warm = try paintOnce(allocator, &diagram, opts, &counting);

    std.debug.assert(cold.output_bytes > 0);

    std.debug.print(
        "{s}: cold_paint={d:.3}ms cold_allocs={d} cold_bytes={d} warm_paint={d:.3}ms warm_allocs={d} warm_bytes={d} output_bytes={d}\n",
        .{
            name,
            nsToMs(cold.elapsed_ns),
            cold.counts.alloc_count,
            cold.counts.bytes_allocated,
            nsToMs(warm.elapsed_ns),
            warm.counts.alloc_count,
            warm.counts.bytes_allocated,
            cold.output_bytes,
        },
    );
}

fn paintOnce(
    allocator: std.mem.Allocator,
    diagram: *const mermaid.Diagram,
    opts: mermaid.PaintOptions,
    counting: *const bench.CountingAllocator,
) !PaintResult {
    var sink: [4096]u8 = undefined;
    var discarding: std.io.Writer.Discarding = .init(&sink);

    const before = counting.snapshot();
    var timer = try std.time.Timer.start();
    try mermaid.paint(&discarding.writer, allocator, diagram, opts);
    const elapsed_ns = timer.read();
    const after = counting.snapshot();

    return .{
        .elapsed_ns = elapsed_ns,
        .counts = bench.CounterSnapshot.diff(after, before),
        .output_bytes = discarding.fullCount(),
    };
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn makeFlowchartSource(allocator: std.mem.Allocator, node_count: usize) ![]u8 {
    std.debug.assert(node_count >= 2);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    try writer.writeAll("graph TD\n");
    for (0..node_count) |i| {
        try writer.print("    N{d}[Node {d}]\n", .{ i, i });
    }
    for (0..node_count - 1) |i| {
        try writer.print("    N{d} --> N{d}\n", .{ i, i + 1 });
    }

    return out.toOwnedSlice(allocator);
}

const sequence_sample =
    \\sequenceDiagram
    \\    participant Alice
    \\    participant Bob
    \\    Alice->>Bob: hi
    \\    Bob-->>Alice: reply
    \\    Alice->>Bob: another
    \\    Bob-->>Alice: ack
    \\
;

const class_sample =
    \\classDiagram
    \\    class Animal {
    \\      +String name
    \\      +int age
    \\      +move()
    \\    }
    \\    class Dog {
    \\      +String breed
    \\      +bark()
    \\    }
    \\    Animal <|-- Dog
    \\
;

const er_sample =
    \\erDiagram
    \\    CUSTOMER ||--o{ ORDER : places
    \\    ORDER ||--|{ LINE_ITEM : contains
    \\    CUSTOMER }|..|{ DELIVERY_ADDRESS : uses
    \\
;

const gitgraph_sample =
    \\gitGraph
    \\    commit
    \\    commit
    \\    branch develop
    \\    checkout develop
    \\    commit
    \\    checkout main
    \\    merge develop
    \\
;

const xychart_sample =
    \\xychart
    \\    title "Demo"
    \\    x-axis [Jan, Feb, Mar]
    \\    y-axis "Value" 0 --> 100
    \\    bar [30, 50, 80]
    \\    line [10, 25, 40]
    \\
;
