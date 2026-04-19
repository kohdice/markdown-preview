const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const ts_cpp_dep = b.dependency("tree_sitter_cpp", .{});
    const ts_typescript_dep = b.dependency("tree_sitter_typescript", .{});
    const ts_html_dep = b.dependency("tree_sitter_html", .{});
    const ts_css_dep = b.dependency("tree_sitter_css", .{});
    const ts_json_dep = b.dependency("tree_sitter_json", .{});

    const ts_support = prepareTreeSitterSupport(b, .{
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
        .ts_cpp_dep = ts_cpp_dep,
        .ts_typescript_dep = ts_typescript_dep,
        .ts_html_dep = ts_html_dep,
        .ts_css_dep = ts_css_dep,
        .ts_json_dep = ts_json_dep,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    attachTreeSitter(exe_mod, ts_support);

    const exe = b.addExecutable(.{
        .name = "mp",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench_inline.zig"),
        .target = target,
        .optimize = optimize,
    });
    attachTreeSitter(bench_mod, ts_support);

    const bench_exe = b.addExecutable(.{
        .name = "inline-bench",
        .root_module = bench_mod,
    });

    const bench_render_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench_render.zig"),
        .target = target,
        .optimize = optimize,
    });
    attachTreeSitter(bench_render_mod, ts_support);

    const bench_render_exe = b.addExecutable(.{
        .name = "render-bench",
        .root_module = bench_render_mod,
    });

    const bench_support_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench_support.zig"),
        .target = target,
        .optimize = optimize,
    });

    const markdown_preview_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    attachTreeSitter(markdown_preview_mod, ts_support);

    bench_mod.addImport("markdown_preview", markdown_preview_mod);
    bench_render_mod.addImport("markdown_preview", markdown_preview_mod);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const bench_step = b.step("bench-inline", "Run inline parser/render benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    const bench_render_step = b.step("bench-render", "Run table render benchmarks");
    const run_bench_render = b.addRunArtifact(bench_render_exe);
    bench_render_step.dependOn(&run_bench_render.step);

    const test_step = b.step("test", "Run tests");
    const test_roots = [_]struct {
        path: []const u8,
        needs_tree_sitter: bool,
    }{
        .{ .path = "src/parse.zig", .needs_tree_sitter = false },
        .{ .path = "src/render.zig", .needs_tree_sitter = true },
        .{ .path = "test/test.zig", .needs_tree_sitter = true },
        .{ .path = "src/cli.zig", .needs_tree_sitter = true },
        .{ .path = "src/term/terminal.zig", .needs_tree_sitter = false },
        .{ .path = "src/term/highlight.zig", .needs_tree_sitter = true },
        .{ .path = "src/text.zig", .needs_tree_sitter = false },
        .{ .path = "src/term/width.zig", .needs_tree_sitter = false },
        .{ .path = "src/term/ansi.zig", .needs_tree_sitter = false },
        .{ .path = "src/watch/file_watcher.zig", .needs_tree_sitter = false },
        .{ .path = "src/watch/raw_term.zig", .needs_tree_sitter = false },
        .{ .path = "src/watch/render_buffer.zig", .needs_tree_sitter = false },
        .{ .path = "src/mermaid.zig", .needs_tree_sitter = false },
    };

    for (test_roots) |test_root| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_root.path),
            .target = target,
            .optimize = optimize,
        });
        if (test_root.needs_tree_sitter) {
            attachTreeSitter(test_mod, ts_support);
        }
        test_mod.addImport("bench_support", bench_support_mod);
        if (std.mem.eql(u8, test_root.path, "test/test.zig")) {
            test_mod.addImport("markdown_preview", markdown_preview_mod);
        }

        const unit_tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
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
    ts_cpp_dep: *std.Build.Dependency,
    ts_typescript_dep: *std.Build.Dependency,
    ts_html_dep: *std.Build.Dependency,
    ts_css_dep: *std.Build.Dependency,
    ts_json_dep: *std.Build.Dependency,
};

/// Grammar C sources and query assets shipped inside each tree-sitter
/// grammar tarball. Most grammars drop their Zig bindings upstream, so
/// we compile `parser.c` (+ optional `scanner.c`) ourselves and embed
/// `queries/highlights.scm` via a build-time wrapper module.
const GrammarSource = struct {
    dep: *std.Build.Dependency,
    has_scanner: bool,
    embed_name: []const u8,
    /// Directory containing parser.c relative to the dep root. Defaults
    /// to "src". tree-sitter-typescript uses "typescript/src" and
    /// "tsx/src" because it ships two parsers in one repository.
    src_subdir: ?[]const u8 = null,
};

const TreeSitterSupport = struct {
    runtime_module: *std.Build.Module,
    zig_module: *std.Build.Module,
    queries_module: *std.Build.Module,
    c_lib: *std.Build.Step.Compile,
    rust_lib: *std.Build.Step.Compile,
    go_lib: *std.Build.Step.Compile,
    python_lib: *std.Build.Step.Compile,
    javascript_lib: *std.Build.Step.Compile,
    bash_lib: *std.Build.Step.Compile,
    cpp_lib: *std.Build.Step.Compile,
    typescript_lib: *std.Build.Step.Compile,
    tsx_lib: *std.Build.Step.Compile,
    html_lib: *std.Build.Step.Compile,
    css_lib: *std.Build.Step.Compile,
    json_lib: *std.Build.Step.Compile,
};

/// Prepare tree-sitter runtime state once, then attach it to any module that
/// directly imports engine files. This keeps the CLI root module and the
/// library facade aligned without duplicating grammar compilation steps.
fn prepareTreeSitterSupport(b: *std.Build, a: TreeSitterAttach) TreeSitterSupport {
    const runtime_module = a.ts_dep.module("tree_sitter");
    const zig_module = a.ts_zig_dep.module("tree-sitter-zig");

    const c_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_c_dep,
        .has_scanner = false,
        .embed_name = "c_highlights.scm",
    }, "tree-sitter-c");
    const rust_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_rust_dep,
        .has_scanner = true,
        .embed_name = "rust_highlights.scm",
    }, "tree-sitter-rust");
    const go_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_go_dep,
        .has_scanner = false,
        .embed_name = "go_highlights.scm",
    }, "tree-sitter-go");
    const python_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_python_dep,
        .has_scanner = true,
        .embed_name = "python_highlights.scm",
    }, "tree-sitter-python");
    const javascript_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_javascript_dep,
        .has_scanner = true,
        .embed_name = "javascript_highlights.scm",
    }, "tree-sitter-javascript");
    const bash_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_bash_dep,
        .has_scanner = true,
        .embed_name = "bash_highlights.scm",
    }, "tree-sitter-bash");
    const cpp_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_cpp_dep,
        .has_scanner = true,
        .embed_name = "cpp_extra_highlights.scm",
    }, "tree-sitter-cpp");
    const typescript_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_typescript_dep,
        .has_scanner = true,
        .embed_name = "typescript_highlights.scm",
        .src_subdir = "typescript/src",
    }, "tree-sitter-typescript");
    const tsx_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_typescript_dep,
        .has_scanner = true,
        .embed_name = "tsx_highlights.scm",
        .src_subdir = "tsx/src",
    }, "tree-sitter-tsx");
    const html_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_html_dep,
        .has_scanner = true,
        .embed_name = "html_highlights.scm",
    }, "tree-sitter-html");
    const css_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_css_dep,
        .has_scanner = true,
        .embed_name = "css_highlights.scm",
    }, "tree-sitter-css");
    const json_lib = compileGrammarLibrary(b, a.target, a.optimize, .{
        .dep = a.ts_json_dep,
        .has_scanner = false,
        .embed_name = "json_highlights.scm",
    }, "tree-sitter-json");

    const queries = b.addWriteFiles();
    _ = queries.addCopyFile(a.ts_zig_dep.path("queries/highlights.scm"), "zig_highlights.scm");
    _ = queries.addCopyFile(a.ts_c_dep.path("queries/highlights.scm"), "c_highlights.scm");
    _ = queries.addCopyFile(a.ts_rust_dep.path("queries/highlights.scm"), "rust_highlights.scm");
    _ = queries.addCopyFile(a.ts_go_dep.path("queries/highlights.scm"), "go_highlights.scm");
    _ = queries.addCopyFile(a.ts_python_dep.path("queries/highlights.scm"), "python_highlights.scm");
    _ = queries.addCopyFile(a.ts_javascript_dep.path("queries/highlights.scm"), "javascript_base_highlights.scm");
    _ = queries.addCopyFile(a.ts_javascript_dep.path("queries/highlights-jsx.scm"), "javascript_jsx_highlights.scm");
    _ = queries.addCopyFile(a.ts_javascript_dep.path("queries/locals.scm"), "javascript_locals.scm");
    _ = queries.addCopyFile(a.ts_bash_dep.path("queries/highlights.scm"), "bash_highlights.scm");
    _ = queries.addCopyFile(a.ts_cpp_dep.path("queries/highlights.scm"), "cpp_extra_highlights.scm");
    _ = queries.addCopyFile(a.ts_typescript_dep.path("queries/highlights.scm"), "typescript_extra_highlights.scm");
    _ = queries.addCopyFile(a.ts_typescript_dep.path("queries/locals.scm"), "typescript_extra_locals.scm");
    _ = queries.addCopyFile(a.ts_html_dep.path("queries/highlights.scm"), "html_highlights.scm");
    _ = queries.addCopyFile(a.ts_css_dep.path("queries/highlights.scm"), "css_highlights.scm");
    _ = queries.addCopyFile(a.ts_json_dep.path("queries/highlights.scm"), "json_highlights.scm");

    const wrapper = queries.add("mod.zig",
        \\pub const zig_highlights: []const u8 = @embedFile("zig_highlights.scm");
        \\pub const c_highlights: []const u8 = @embedFile("c_highlights.scm");
        \\pub const rust_highlights: []const u8 = @embedFile("rust_highlights.scm");
        \\pub const go_highlights: []const u8 = @embedFile("go_highlights.scm");
        \\pub const python_highlights: []const u8 = @embedFile("python_highlights.scm");
        \\pub const bash_highlights: []const u8 = @embedFile("bash_highlights.scm");
        \\pub const html_highlights: []const u8 = @embedFile("html_highlights.scm");
        \\pub const css_highlights: []const u8 = @embedFile("css_highlights.scm");
        \\pub const json_highlights: []const u8 = @embedFile("json_highlights.scm");
        \\// Layered highlights for the javascript family. We concatenate
        \\// from most generic to most specific so the more specific child
        \\// patterns win under the highlighter's "later pattern wins" rule
        \\// (e.g. `(jsx_attribute (property_identifier) @attribute)` needs
        \\// to come after the generic `(property_identifier) @property`
        \\// in the javascript base highlights, otherwise jsx attributes
        \\// render as CSS-style properties).
        \\const javascript_base_highlights: []const u8 = @embedFile("javascript_base_highlights.scm");
        \\const javascript_jsx_highlights: []const u8 = @embedFile("javascript_jsx_highlights.scm");
        \\const typescript_extra_highlights: []const u8 = @embedFile("typescript_extra_highlights.scm");
        \\pub const javascript_highlights: []const u8 = javascript_base_highlights ++ "\n" ++ javascript_jsx_highlights;
        \\pub const typescript_highlights: []const u8 = javascript_base_highlights ++ "\n" ++ typescript_extra_highlights;
        \\pub const tsx_highlights: []const u8 = javascript_base_highlights ++ "\n" ++ javascript_jsx_highlights ++ "\n" ++ typescript_extra_highlights;
        \\// cpp highlights.scm is similarly a semantic shim over c.
        \\pub const cpp_highlights: []const u8 = c_highlights ++ "\n" ++ @embedFile("cpp_extra_highlights.scm");
        \\// Locals queries. Upstream assigns typescript a [ts_extra, js]
        \\// stack and tsx js-only; we mirror that here.
        \\pub const javascript_locals: []const u8 = @embedFile("javascript_locals.scm");
        \\pub const typescript_locals: []const u8 = @embedFile("typescript_extra_locals.scm") ++ "\n" ++ javascript_locals;
        \\pub const tsx_locals: []const u8 = javascript_locals;
        \\
    );

    return .{
        .runtime_module = runtime_module,
        .zig_module = zig_module,
        .queries_module = b.createModule(.{
            .root_source_file = wrapper,
            .target = a.target,
            .optimize = a.optimize,
        }),
        .c_lib = c_lib,
        .rust_lib = rust_lib,
        .go_lib = go_lib,
        .python_lib = python_lib,
        .javascript_lib = javascript_lib,
        .bash_lib = bash_lib,
        .cpp_lib = cpp_lib,
        .typescript_lib = typescript_lib,
        .tsx_lib = tsx_lib,
        .html_lib = html_lib,
        .css_lib = css_lib,
        .json_lib = json_lib,
    };
}

fn compileGrammarLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src: GrammarSource,
    lib_name: []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = lib_name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const subdir = src.src_subdir orelse "src";
    const parser_path = b.fmt("{s}/parser.c", .{subdir});
    lib.addCSourceFile(.{
        .file = src.dep.path(parser_path),
        .flags = &.{"-std=c11"},
    });
    if (src.has_scanner) {
        const scanner_path = b.fmt("{s}/scanner.c", .{subdir});
        lib.addCSourceFile(.{
            .file = src.dep.path(scanner_path),
            .flags = &.{"-std=c11"},
        });
    }
    lib.addIncludePath(src.dep.path(subdir));
    return lib;
}

/// Attach tree-sitter runtime and grammar assets to a module that directly
/// compiles engine code.
fn attachTreeSitter(module: *std.Build.Module, support: TreeSitterSupport) void {
    module.addImport("tree_sitter", support.runtime_module);
    // tree-sitter-zig is still packaged with Zig bindings upstream, so we can
    // reuse its module directly.
    module.addImport("tree-sitter-zig", support.zig_module);
    module.addImport("ts_queries", support.queries_module);
    module.linkLibrary(support.c_lib);
    module.linkLibrary(support.rust_lib);
    module.linkLibrary(support.go_lib);
    module.linkLibrary(support.python_lib);
    module.linkLibrary(support.javascript_lib);
    module.linkLibrary(support.bash_lib);
    module.linkLibrary(support.cpp_lib);
    module.linkLibrary(support.typescript_lib);
    module.linkLibrary(support.tsx_lib);
    module.linkLibrary(support.html_lib);
    module.linkLibrary(support.css_lib);
    module.linkLibrary(support.json_lib);
}
