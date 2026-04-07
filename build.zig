const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("markdown_preview", .{
        .root_source_file = b.path("src/markdown_preview.zig"),
        .target = target,
    });

    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    // build-shared=false forces tree-sitter-zig to compile as a static library
    // so the installed `mp` binary does not keep a dlopen-style dependency on
    // `libtree-sitter-zig.dylib` sitting inside .zig-cache.
    const ts_zig_dep = b.dependency("tree_sitter_zig", .{
        .target = target,
        .optimize = optimize,
        .@"build-shared" = false,
    });
    const ts_c_dep = b.dependency("tree_sitter_c", .{});
    const ts_rust_dep = b.dependency("tree_sitter_rust", .{});
    const ts_go_dep = b.dependency("tree_sitter_go", .{});
    const ts_python_dep = b.dependency("tree_sitter_python", .{});
    const ts_javascript_dep = b.dependency("tree_sitter_javascript", .{});
    const ts_bash_dep = b.dependency("tree_sitter_bash", .{});

    attachTreeSitter(b, mod, .{
        .target = target,
        .optimize = optimize,
        .ts_dep = ts_dep,
        .ts_zig_dep = ts_zig_dep,
        .ts_c_dep = ts_c_dep,
        .ts_rust_dep = ts_rust_dep,
        .ts_go_dep = ts_go_dep,
        .ts_python_dep = ts_python_dep,
        .ts_javascript_dep = ts_javascript_dep,
        .ts_bash_dep = ts_bash_dep,
    });

    const exe = b.addExecutable(.{
        .name = "mp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "markdown_preview", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

/// Options bundle for `attachTreeSitter`. Keeping the argument list as one
/// struct avoids a sprawling positional signature and makes each grammar
/// dependency self-documenting at the call site.
const TreeSitterAttach = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ts_dep: *std.Build.Dependency,
    ts_zig_dep: *std.Build.Dependency,
    ts_c_dep: *std.Build.Dependency,
    ts_rust_dep: *std.Build.Dependency,
    ts_go_dep: *std.Build.Dependency,
    ts_python_dep: *std.Build.Dependency,
    ts_javascript_dep: *std.Build.Dependency,
    ts_bash_dep: *std.Build.Dependency,
};

/// Grammar C sources and query assets shipped inside each tree-sitter
/// grammar tarball. Most grammars drop their Zig bindings upstream, so
/// we compile `parser.c` (+ optional `scanner.c`) ourselves and embed
/// `queries/highlights.scm` via a build-time wrapper module.
const GrammarSource = struct {
    dep: *std.Build.Dependency,
    has_scanner: bool,
    embed_name: []const u8, // key used by @embedFile in the wrapper
};

/// Attach tree-sitter runtime and all grammar libraries to a module.
///
/// Propagation: Called once on `mod` (the library module).
/// - `mod_tests` uses `mod` as its root_module → inherits imports + C link.
/// - `exe.root_module` imports `mod` via the `markdown_preview` named module
///   so the exe compile unit never re-includes library files directly;
///   tree_sitter resolution therefore stays inside `mod`.
/// - `exe_tests` uses `exe.root_module` → also inherits.
fn attachTreeSitter(b: *std.Build, module: *std.Build.Module, a: TreeSitterAttach) void {
    module.addImport("tree_sitter", a.ts_dep.module("tree_sitter"));
    // tree-sitter-zig is still packaged with Zig bindings upstream, so we can
    // reuse its module directly.
    module.addImport("tree-sitter-zig", a.ts_zig_dep.module("tree-sitter-zig"));

    const grammars = [_]struct {
        src: GrammarSource,
        lib_name: []const u8,
    }{
        .{ .src = .{ .dep = a.ts_c_dep, .has_scanner = false, .embed_name = "c_highlights.scm" }, .lib_name = "tree-sitter-c" },
        .{ .src = .{ .dep = a.ts_rust_dep, .has_scanner = true, .embed_name = "rust_highlights.scm" }, .lib_name = "tree-sitter-rust" },
        .{ .src = .{ .dep = a.ts_go_dep, .has_scanner = false, .embed_name = "go_highlights.scm" }, .lib_name = "tree-sitter-go" },
        .{ .src = .{ .dep = a.ts_python_dep, .has_scanner = true, .embed_name = "python_highlights.scm" }, .lib_name = "tree-sitter-python" },
        .{ .src = .{ .dep = a.ts_javascript_dep, .has_scanner = true, .embed_name = "javascript_highlights.scm" }, .lib_name = "tree-sitter-javascript" },
        .{ .src = .{ .dep = a.ts_bash_dep, .has_scanner = true, .embed_name = "bash_highlights.scm" }, .lib_name = "tree-sitter-bash" },
    };

    for (grammars) |g| {
        const lib = b.addLibrary(.{
            .name = g.lib_name,
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = a.target,
                .optimize = a.optimize,
                .link_libc = true,
            }),
        });
        lib.addCSourceFile(.{
            .file = g.src.dep.path("src/parser.c"),
            .flags = &.{"-std=c11"},
        });
        if (g.src.has_scanner) {
            lib.addCSourceFile(.{
                .file = g.src.dep.path("src/scanner.c"),
                .flags = &.{"-std=c11"},
            });
        }
        lib.addIncludePath(g.src.dep.path("src"));
        module.linkLibrary(lib);
    }

    // Embed highlights.scm query files via a build-time generated wrapper
    // module. @embedFile resolves relative to the wrapper Zig source file,
    // so we copy each .scm next to the wrapper and reference it by a fixed
    // filename.
    const queries = b.addWriteFiles();
    _ = queries.addCopyFile(a.ts_zig_dep.path("queries/highlights.scm"), "zig_highlights.scm");
    _ = queries.addCopyFile(a.ts_c_dep.path("queries/highlights.scm"), "c_highlights.scm");
    _ = queries.addCopyFile(a.ts_rust_dep.path("queries/highlights.scm"), "rust_highlights.scm");
    _ = queries.addCopyFile(a.ts_go_dep.path("queries/highlights.scm"), "go_highlights.scm");
    _ = queries.addCopyFile(a.ts_python_dep.path("queries/highlights.scm"), "python_highlights.scm");
    _ = queries.addCopyFile(a.ts_javascript_dep.path("queries/highlights.scm"), "javascript_highlights.scm");
    _ = queries.addCopyFile(a.ts_bash_dep.path("queries/highlights.scm"), "bash_highlights.scm");

    const wrapper = queries.add("mod.zig",
        \\pub const zig_highlights: []const u8 = @embedFile("zig_highlights.scm");
        \\pub const c_highlights: []const u8 = @embedFile("c_highlights.scm");
        \\pub const rust_highlights: []const u8 = @embedFile("rust_highlights.scm");
        \\pub const go_highlights: []const u8 = @embedFile("go_highlights.scm");
        \\pub const python_highlights: []const u8 = @embedFile("python_highlights.scm");
        \\pub const javascript_highlights: []const u8 = @embedFile("javascript_highlights.scm");
        \\pub const bash_highlights: []const u8 = @embedFile("bash_highlights.scm");
        \\
    );
    module.addAnonymousImport("ts_queries", .{
        .root_source_file = wrapper,
    });
}
