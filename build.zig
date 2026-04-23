const std = @import("std");

const TestRoot = struct {
    path: []const u8,
    needs_tree_sitter: bool,
    needs_internals: bool = false,
};

const test_roots = [_]TestRoot{
    .{ .path = "src/parse.zig", .needs_tree_sitter = false },
    .{ .path = "src/render.zig", .needs_tree_sitter = true },
    .{ .path = "src/lib.zig", .needs_tree_sitter = true },
    .{ .path = "test/test.zig", .needs_tree_sitter = true, .needs_internals = true },
    .{ .path = "src/cli.zig", .needs_tree_sitter = true },
    .{ .path = "src/term/terminal.zig", .needs_tree_sitter = false },
    .{ .path = "src/term/highlight.zig", .needs_tree_sitter = true },
    .{ .path = "src/text.zig", .needs_tree_sitter = false },
    .{ .path = "src/term/width.zig", .needs_tree_sitter = false },
    .{ .path = "src/term/ansi.zig", .needs_tree_sitter = false },
    .{ .path = "src/watch/file_watcher.zig", .needs_tree_sitter = false },
    .{ .path = "src/term/raw.zig", .needs_tree_sitter = false },
    .{ .path = "src/watch/render_buffer.zig", .needs_tree_sitter = false },
    .{ .path = "src/watch/content_hash.zig", .needs_tree_sitter = false },
    .{ .path = "src/watch/debounce.zig", .needs_tree_sitter = false },
    .{ .path = "src/mermaid.zig", .needs_tree_sitter = false },
    .{ .path = "src/source_loader.zig", .needs_tree_sitter = false },
    .{ .path = "src/backing_allocator.zig", .needs_tree_sitter = false },
    .{ .path = "src/stdout_buffer.zig", .needs_tree_sitter = false },
    .{ .path = "src/write_error.zig", .needs_tree_sitter = false },
    .{ .path = "bench/bench_support.zig", .needs_tree_sitter = false },
};

const queries_wrapper_source =
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
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ts_deps = loadTreeSitterDependencies(b, target, optimize);
    const ts_support = prepareTreeSitterSupport(b, target, optimize, ts_deps);

    const source_mod = createModule(b, "src/source.zig", target, optimize);
    const bench_support_mod = createModule(b, "bench/bench_support.zig", target, optimize);
    const bench_fixtures_mod = createModule(b, "bench/fixtures.zig", target, optimize);
    const render_buffer_mod = createModule(b, "src/watch/render_buffer.zig", target, optimize);

    const mermaid_mod = createModule(b, "src/mermaid.zig", target, optimize);
    mermaid_mod.addImport("source", source_mod);

    // Internal aggregation module exposing parse/render/source_loader/term
    // plus the public `facade` (src/lib.zig) for bench harnesses and
    // integration tests. External callers still use the facade directly
    // via src/lib.zig; the re-export here only lets tests exercise both
    // the facade contract and lower-level helpers from a single module.
    const internals_mod = createTreeSitterModule(b, "src/internals.zig", target, optimize, ts_support);
    internals_mod.addImport("source", source_mod);

    const exe = addMpExecutable(b, "mp", target, optimize, source_mod, ts_support);
    b.installArtifact(exe);

    const benches = addBenchExecutables(b, target, optimize, .{
        .fixtures = bench_fixtures_mod,
        .mermaid = mermaid_mod,
        .render_buffer = render_buffer_mod,
        .internals = internals_mod,
    });

    addArtifactRunStep(b, "run", "Run the app", exe, .{
        .depend_on_install = true,
        .forward_build_args = true,
    });
    addBenchSteps(b, benches);
    addTestStep(b, target, optimize, source_mod, bench_support_mod, internals_mod, ts_support, benches);
}

const BenchModules = struct {
    fixtures: *std.Build.Module,
    mermaid: *std.Build.Module,
    render_buffer: *std.Build.Module,
    internals: *std.Build.Module,
};

const BenchArtifacts = struct {
    fixtures_bench: *std.Build.Step.Compile,
    inline_bench: *std.Build.Step.Compile,
    render_bench: *std.Build.Step.Compile,
    mermaid_bench: *std.Build.Step.Compile,
    watch_buffer_bench: *std.Build.Step.Compile,
    pipeline_bench: *std.Build.Step.Compile,

    fn compileTargets(self: @This()) [6]*std.Build.Step.Compile {
        return .{
            self.fixtures_bench,
            self.inline_bench,
            self.render_bench,
            self.mermaid_bench,
            self.watch_buffer_bench,
            self.pipeline_bench,
        };
    }
};

const RunStepOptions = struct {
    depend_on_install: bool = false,
    forward_build_args: bool = false,
};

fn createModule(
    b: *std.Build,
    root_source_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_path),
        .target = target,
        .optimize = optimize,
    });
}

fn createTreeSitterModule(
    b: *std.Build,
    root_source_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ts_support: TreeSitterSupport,
) *std.Build.Module {
    const module = createModule(b, root_source_path, target, optimize);
    attachTreeSitter(module, ts_support);
    return module;
}

fn addExecutableArtifact(
    b: *std.Build,
    name: []const u8,
    module: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
}

fn addMpExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_mod: *std.Build.Module,
    ts_support: TreeSitterSupport,
) *std.Build.Step.Compile {
    const exe_mod = createTreeSitterModule(b, "src/main.zig", target, optimize, ts_support);
    exe_mod.addImport("source", source_mod);
    return addExecutableArtifact(b, name, exe_mod);
}

fn addBenchExecutables(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bench_modules: BenchModules,
) BenchArtifacts {
    const fixtures_mod = createModule(b, "bench/bench_fixtures.zig", target, optimize);
    fixtures_mod.addImport("fixtures", bench_modules.fixtures);

    const inline_mod = createModule(b, "bench/bench_inline.zig", target, optimize);
    inline_mod.addImport("internals", bench_modules.internals);

    const render_mod = createModule(b, "bench/bench_render.zig", target, optimize);
    render_mod.addImport("internals", bench_modules.internals);

    const mermaid_mod = createModule(b, "bench/bench_mermaid.zig", target, optimize);
    mermaid_mod.addImport("mermaid", bench_modules.mermaid);

    const watch_buffer_mod = createModule(b, "bench/bench_watch_buffer.zig", target, optimize);
    watch_buffer_mod.addImport("render_buffer", bench_modules.render_buffer);

    const pipeline_mod = createModule(b, "bench/bench_pipeline.zig", target, optimize);
    pipeline_mod.addImport("internals", bench_modules.internals);
    pipeline_mod.addImport("fixtures", bench_modules.fixtures);

    return .{
        .fixtures_bench = addExecutableArtifact(b, "bench-fixtures", fixtures_mod),
        .inline_bench = addExecutableArtifact(b, "inline-bench", inline_mod),
        .render_bench = addExecutableArtifact(b, "render-bench", render_mod),
        .mermaid_bench = addExecutableArtifact(b, "mermaid-bench", mermaid_mod),
        .watch_buffer_bench = addExecutableArtifact(b, "watch-buffer-bench", watch_buffer_mod),
        .pipeline_bench = addExecutableArtifact(b, "pipeline-bench", pipeline_mod),
    };
}

fn addArtifactRunStep(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    artifact: *std.Build.Step.Compile,
    options: RunStepOptions,
) void {
    const step = b.step(step_name, description);
    const run_cmd = b.addRunArtifact(artifact);
    step.dependOn(&run_cmd.step);

    if (options.depend_on_install) {
        run_cmd.step.dependOn(b.getInstallStep());
    }
    if (options.forward_build_args) {
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}

fn addBenchSteps(b: *std.Build, benches: BenchArtifacts) void {
    addArtifactRunStep(b, "bench-fixtures", "Generate cached benchmark fixtures", benches.fixtures_bench, .{});
    addArtifactRunStep(b, "bench-inline", "Run inline parser/render benchmarks", benches.inline_bench, .{});
    addArtifactRunStep(b, "bench-render", "Run table render benchmarks", benches.render_bench, .{});
    addArtifactRunStep(b, "bench-mermaid", "Run Mermaid compile/paint benchmarks", benches.mermaid_bench, .{});
    addArtifactRunStep(b, "bench-watch-buffer", "Run RenderBuffer microbenchmark", benches.watch_buffer_bench, .{});
    addArtifactRunStep(b, "bench-pipeline", "Run parse + render pipeline benchmark", benches.pipeline_bench, .{
        .forward_build_args = true,
    });
}

fn addTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_mod: *std.Build.Module,
    bench_support_mod: *std.Build.Module,
    internals_mod: *std.Build.Module,
    ts_support: TreeSitterSupport,
    benches: BenchArtifacts,
) void {
    const test_step = b.step("test", "Run tests");

    for (test_roots) |test_root| {
        const test_mod = createModule(b, test_root.path, target, optimize);
        if (test_root.needs_tree_sitter) {
            attachTreeSitter(test_mod, ts_support);
        }
        test_mod.addImport("bench_support", bench_support_mod);
        test_mod.addImport("source", source_mod);
        if (test_root.needs_internals) {
            test_mod.addImport("internals", internals_mod);
        }

        const unit_tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    for (benches.compileTargets()) |bench_target| {
        test_step.dependOn(&bench_target.step);
    }
}

const GrammarDependencies = struct {
    c: *std.Build.Dependency,
    rust: *std.Build.Dependency,
    go: *std.Build.Dependency,
    python: *std.Build.Dependency,
    javascript: *std.Build.Dependency,
    bash: *std.Build.Dependency,
    cpp: *std.Build.Dependency,
    typescript: *std.Build.Dependency,
    html: *std.Build.Dependency,
    css: *std.Build.Dependency,
    json: *std.Build.Dependency,
};

const TreeSitterDependencies = struct {
    runtime: *std.Build.Dependency,
    zig: *std.Build.Dependency,
    grammars: GrammarDependencies,
};

fn loadTreeSitterDependencies(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) TreeSitterDependencies {
    return .{
        .runtime = b.dependency("tree_sitter", .{
            .target = target,
            .optimize = optimize,
        }),
        // build-shared=false forces tree-sitter-zig to compile as a static library
        // so the installed `mp` binary does not keep a dlopen-style dependency on
        // `libtree-sitter-zig.dylib` sitting inside .zig-cache.
        .zig = b.dependency("tree_sitter_zig", .{
            .target = target,
            .optimize = optimize,
            .@"build-shared" = false,
        }),
        .grammars = .{
            .c = b.dependency("tree_sitter_c", .{}),
            .rust = b.dependency("tree_sitter_rust", .{}),
            .go = b.dependency("tree_sitter_go", .{}),
            .python = b.dependency("tree_sitter_python", .{}),
            .javascript = b.dependency("tree_sitter_javascript", .{}),
            .bash = b.dependency("tree_sitter_bash", .{}),
            .cpp = b.dependency("tree_sitter_cpp", .{}),
            .typescript = b.dependency("tree_sitter_typescript", .{}),
            .html = b.dependency("tree_sitter_html", .{}),
            .css = b.dependency("tree_sitter_css", .{}),
            .json = b.dependency("tree_sitter_json", .{}),
        },
    };
}

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

const GrammarLibraries = struct {
    c: *std.Build.Step.Compile,
    rust: *std.Build.Step.Compile,
    go: *std.Build.Step.Compile,
    python: *std.Build.Step.Compile,
    javascript: *std.Build.Step.Compile,
    bash: *std.Build.Step.Compile,
    cpp: *std.Build.Step.Compile,
    typescript: *std.Build.Step.Compile,
    tsx: *std.Build.Step.Compile,
    html: *std.Build.Step.Compile,
    css: *std.Build.Step.Compile,
    json: *std.Build.Step.Compile,
};

const TreeSitterSupport = struct {
    runtime_module: *std.Build.Module,
    zig_module: *std.Build.Module,
    queries_module: *std.Build.Module,
    libs: GrammarLibraries,
};

fn prepareTreeSitterSupport(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: TreeSitterDependencies,
) TreeSitterSupport {
    return .{
        .runtime_module = deps.runtime.module("tree_sitter"),
        .zig_module = deps.zig.module("tree-sitter-zig"),
        .queries_module = createQueriesModule(b, target, optimize, deps),
        .libs = compileGrammarLibraries(b, target, optimize, deps.grammars),
    };
}

fn compileGrammarLibraries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: GrammarDependencies,
) GrammarLibraries {
    return .{
        .c = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.c,
            .has_scanner = false,
            .embed_name = "c_highlights.scm",
        }, "tree-sitter-c"),
        .rust = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.rust,
            .has_scanner = true,
            .embed_name = "rust_highlights.scm",
        }, "tree-sitter-rust"),
        .go = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.go,
            .has_scanner = false,
            .embed_name = "go_highlights.scm",
        }, "tree-sitter-go"),
        .python = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.python,
            .has_scanner = true,
            .embed_name = "python_highlights.scm",
        }, "tree-sitter-python"),
        .javascript = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.javascript,
            .has_scanner = true,
            .embed_name = "javascript_highlights.scm",
        }, "tree-sitter-javascript"),
        .bash = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.bash,
            .has_scanner = true,
            .embed_name = "bash_highlights.scm",
        }, "tree-sitter-bash"),
        .cpp = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.cpp,
            .has_scanner = true,
            .embed_name = "cpp_extra_highlights.scm",
        }, "tree-sitter-cpp"),
        .typescript = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.typescript,
            .has_scanner = true,
            .embed_name = "typescript_highlights.scm",
            .src_subdir = "typescript/src",
        }, "tree-sitter-typescript"),
        .tsx = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.typescript,
            .has_scanner = true,
            .embed_name = "tsx_highlights.scm",
            .src_subdir = "tsx/src",
        }, "tree-sitter-tsx"),
        .html = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.html,
            .has_scanner = true,
            .embed_name = "html_highlights.scm",
        }, "tree-sitter-html"),
        .css = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.css,
            .has_scanner = true,
            .embed_name = "css_highlights.scm",
        }, "tree-sitter-css"),
        .json = compileGrammarLibrary(b, target, optimize, .{
            .dep = deps.json,
            .has_scanner = false,
            .embed_name = "json_highlights.scm",
        }, "tree-sitter-json"),
    };
}

fn createQueriesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: TreeSitterDependencies,
) *std.Build.Module {
    const queries = b.addWriteFiles();
    addGrammarQueries(queries, deps);
    const wrapper = queries.add("mod.zig", queries_wrapper_source);
    return b.createModule(.{
        .root_source_file = wrapper,
        .target = target,
        .optimize = optimize,
    });
}

fn addGrammarQueries(queries: anytype, deps: TreeSitterDependencies) void {
    _ = queries.addCopyFile(deps.zig.path("queries/highlights.scm"), "zig_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.c.path("queries/highlights.scm"), "c_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.rust.path("queries/highlights.scm"), "rust_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.go.path("queries/highlights.scm"), "go_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.python.path("queries/highlights.scm"), "python_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.javascript.path("queries/highlights.scm"), "javascript_base_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.javascript.path("queries/highlights-jsx.scm"), "javascript_jsx_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.javascript.path("queries/locals.scm"), "javascript_locals.scm");
    _ = queries.addCopyFile(deps.grammars.bash.path("queries/highlights.scm"), "bash_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.cpp.path("queries/highlights.scm"), "cpp_extra_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.typescript.path("queries/highlights.scm"), "typescript_extra_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.typescript.path("queries/locals.scm"), "typescript_extra_locals.scm");
    _ = queries.addCopyFile(deps.grammars.html.path("queries/highlights.scm"), "html_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.css.path("queries/highlights.scm"), "css_highlights.scm");
    _ = queries.addCopyFile(deps.grammars.json.path("queries/highlights.scm"), "json_highlights.scm");
}

fn compileGrammarLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src: GrammarSource,
    lib_name: []const u8,
) *std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = lib_name,
        .linkage = .static,
        .root_module = root_module,
    });
    const subdir = src.src_subdir orelse "src";
    const parser_path = b.fmt("{s}/parser.c", .{subdir});
    root_module.addCSourceFile(.{
        .file = src.dep.path(parser_path),
        .flags = &.{"-std=c11"},
    });
    if (src.has_scanner) {
        const scanner_path = b.fmt("{s}/scanner.c", .{subdir});
        root_module.addCSourceFile(.{
            .file = src.dep.path(scanner_path),
            .flags = &.{"-std=c11"},
        });
    }
    root_module.addIncludePath(src.dep.path(subdir));
    return lib;
}

fn attachTreeSitter(module: *std.Build.Module, support: TreeSitterSupport) void {
    module.addImport("tree_sitter", support.runtime_module);
    // tree-sitter-zig is still packaged with Zig bindings upstream, so we can
    // reuse its module directly.
    module.addImport("tree-sitter-zig", support.zig_module);
    module.addImport("ts_queries", support.queries_module);
    inline for (std.meta.fields(GrammarLibraries)) |field| {
        module.linkLibrary(@field(support.libs, field.name));
    }
}
