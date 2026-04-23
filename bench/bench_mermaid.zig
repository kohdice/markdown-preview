const std = @import("std");
const bench = @import("bench_support.zig");
const mermaid = @import("mermaid");

const timing_allocator = std.heap.smp_allocator;

const CompileTimingRunner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,

    pub fn run(self: *@This()) !void {
        var diagram = try mermaid.compile(self.allocator, self.source);
        defer diagram.deinit();
        std.mem.doNotOptimizeAway(&diagram);
    }
};

const PaintTimingRunner = struct {
    allocator: std.mem.Allocator,
    diagram: *const mermaid.Diagram,
    opts: mermaid.PaintOptions,
    last_output_bytes: usize = 0,

    pub fn run(self: *@This()) !void {
        self.last_output_bytes = try paintWithDiscarding(
            self.allocator,
            self.diagram,
            self.opts,
        );
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("mermaid benchmark\n", .{});

    const flowchart_src = try makeFlowchartSource(allocator, 16);
    try runCompile(allocator, io, "flowchart-compile-16", flowchart_src);
    try runPaint(allocator, io, "flowchart-paint-16", flowchart_src);

    try runCompile(allocator, io, "sequence-compile-small", sequence_sample);
    try runCompile(allocator, io, "class-compile-small", class_sample);
    try runCompile(allocator, io, "er-compile-small", er_sample);

    try runPaint(allocator, io, "gitgraph-paint-small", gitgraph_sample);
    try runPaint(allocator, io, "xychart-paint-small", xychart_sample);
}

fn runCompile(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    source: []const u8,
) !void {
    var runner = CompileTimingRunner{
        .allocator = timing_allocator,
        .source = source,
    };
    const timing = try bench.measure(io, sample_allocator, bench.default_measure_options, &runner);
    const counts = try profileCompile(source);

    std.debug.print(
        "{s}: n={d} compile_median={d:.3}ms [{d:.3}..{d:.3}] allocs={d} bytes={d}\n",
        .{
            name,
            timing.sample_count,
            bench.nsToMs(timing.median_ns),
            bench.nsToMs(timing.min_ns),
            bench.nsToMs(timing.max_ns),
            counts.alloc_count,
            counts.bytes_allocated,
        },
    );
}

fn profileCompile(source: []const u8) !bench.CounterSnapshot {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const before = counting.snapshot();
    var diagram = try mermaid.compile(counting.allocator(), source);
    defer diagram.deinit();
    const after = counting.snapshot();
    return bench.CounterSnapshot.diff(after, before);
}

fn runPaint(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    source: []const u8,
) !void {
    var diagram = try mermaid.compile(timing_allocator, source);
    defer diagram.deinit();

    const opts: mermaid.PaintOptions = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    var runner = PaintTimingRunner{
        .allocator = timing_allocator,
        .diagram = &diagram,
        .opts = opts,
    };
    const timing = try bench.measure(io, sample_allocator, bench.default_measure_options, &runner);
    const profile = try profilePaint(source, opts);

    std.debug.print(
        "{s}: n={d} paint_median={d:.3}ms [{d:.3}..{d:.3}] allocs={d} bytes={d} out={d}\n",
        .{
            name,
            timing.sample_count,
            bench.nsToMs(timing.median_ns),
            bench.nsToMs(timing.min_ns),
            bench.nsToMs(timing.max_ns),
            profile.counts.alloc_count,
            profile.counts.bytes_allocated,
            runner.last_output_bytes,
        },
    );
}

const PaintProfile = struct {
    counts: bench.CounterSnapshot,
    output_bytes: usize,
};

fn profilePaint(source: []const u8, opts: mermaid.PaintOptions) !PaintProfile {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const allocator = counting.allocator();

    var diagram = try mermaid.compile(allocator, source);
    defer diagram.deinit();

    const before = counting.snapshot();
    const output_bytes = try paintWithDiscarding(allocator, &diagram, opts);
    const after = counting.snapshot();

    return .{
        .counts = bench.CounterSnapshot.diff(after, before),
        .output_bytes = output_bytes,
    };
}

fn paintWithDiscarding(
    allocator: std.mem.Allocator,
    diagram: *const mermaid.Diagram,
    opts: mermaid.PaintOptions,
) !usize {
    var sink: [4096]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    try mermaid.paint(&discarding.writer, allocator, diagram, opts);
    try discarding.writer.flush();
    const output_bytes = discarding.fullCount();
    std.mem.doNotOptimizeAway(output_bytes);
    return output_bytes;
}

fn makeFlowchartSource(allocator: std.mem.Allocator, node_count: usize) ![]u8 {
    std.debug.assert(node_count >= 2);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    try writer.writeAll("graph TD\n");
    for (0..node_count) |i| {
        try writer.print("    N{d}[Node {d}]\n", .{ i, i });
    }
    for (0..node_count - 1) |i| {
        try writer.print("    N{d} --> N{d}\n", .{ i, i + 1 });
    }

    return aw.toOwnedSlice();
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
