const std = @import("std");
const env_like_contract = @import("src/term/env_like.zig");
const manifest = @import("build.zig.zon");

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
    .{ .path = "src/mermaid.zig", .needs_tree_sitter = false },
    .{ .path = "src/source_loader.zig", .needs_tree_sitter = false },
    .{ .path = "src/stdout_buffer.zig", .needs_tree_sitter = false },
    .{ .path = "src/write_error.zig", .needs_tree_sitter = false },
    .{ .path = "bench/bench_support.zig", .needs_tree_sitter = false },
};

const QueryAssetSpec = struct {
    dep_path: []const u8,
    output_name: []const u8,
    binding_name: []const u8,
    is_public: bool = true,
};

const QueryExportSpec = struct {
    name: []const u8,
    parts: []const []const u8,
    is_public: bool = true,
};

const PackageDependencyStyle = enum {
    plain,
    targeted_static,
};

const PackageSpec = struct {
    name: []const u8,
    dependency_style: PackageDependencyStyle = .plain,
    module_name: ?[]const u8 = null,
};

const package_specs = [_]PackageSpec{
    .{
        .name = "tree_sitter_zig",
        .dependency_style = .targeted_static,
        .module_name = "tree-sitter-zig",
    },
    .{ .name = "tree_sitter_c" },
    .{ .name = "tree_sitter_rust" },
    .{ .name = "tree_sitter_go" },
    .{ .name = "tree_sitter_bash" },
    .{ .name = "tree_sitter_json" },
};

fn packageIndexByName(comptime name: []const u8) usize {
    inline for (package_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.name, name)) return i;
    }
    @compileError("missing package spec for package " ++ name);
}

fn packageIndexByModuleName(comptime module_name: []const u8) usize {
    inline for (package_specs, 0..) |spec, i| {
        if (spec.module_name) |name| {
            if (std.mem.eql(u8, name, module_name)) return i;
        }
    }
    @compileError("missing package spec for module " ++ module_name);
}

const GrammarSpec = struct {
    package_index: usize,
    lib_name: ?[]const u8 = null,
    has_scanner: bool = false,
    src_subdir: ?[]const u8 = null,
    query_assets: []const QueryAssetSpec = &.{},
    query_exports: []const QueryExportSpec = &.{},
};

const grammar_specs = [_]GrammarSpec{
    .{
        .package_index = packageIndexByName("tree_sitter_zig"),
        .query_assets = &.{
            .{
                .dep_path = "queries/highlights.scm",
                .output_name = "zig_highlights.scm",
                .binding_name = "zig_highlights",
            },
        },
    },
    .{
        .package_index = packageIndexByName("tree_sitter_c"),
        .lib_name = "tree-sitter-c",
        .query_assets = &.{
            .{
                .dep_path = "queries/highlights.scm",
                .output_name = "c_highlights.scm",
                .binding_name = "c_highlights",
            },
        },
    },
    .{
        .package_index = packageIndexByName("tree_sitter_rust"),
        .lib_name = "tree-sitter-rust",
        .has_scanner = true,
        .query_assets = &.{
            .{
                .dep_path = "queries/highlights.scm",
                .output_name = "rust_highlights.scm",
                .binding_name = "rust_highlights",
            },
        },
    },
    .{
        .package_index = packageIndexByName("tree_sitter_go"),
        .lib_name = "tree-sitter-go",
        .query_assets = &.{
            .{
                .dep_path = "queries/highlights.scm",
                .output_name = "go_highlights.scm",
                .binding_name = "go_highlights",
            },
        },
    },
    .{
        .package_index = packageIndexByName("tree_sitter_bash"),
        .lib_name = "tree-sitter-bash",
        .has_scanner = true,
        .query_assets = &.{
            .{
                .dep_path = "queries/highlights.scm",
                .output_name = "bash_highlights.scm",
                .binding_name = "bash_highlights",
            },
        },
    },
    .{
        .package_index = packageIndexByName("tree_sitter_json"),
        .lib_name = "tree-sitter-json",
        .query_assets = &.{
            .{
                .dep_path = "queries/highlights.scm",
                .output_name = "json_highlights.scm",
                .binding_name = "json_highlights",
            },
        },
    },
};

fn queryAssetBindingExists(comptime binding_name: []const u8) bool {
    inline for (grammar_specs) |spec| {
        inline for (spec.query_assets) |asset| {
            if (std.mem.eql(u8, asset.binding_name, binding_name)) return true;
        }
    }
    return false;
}

fn validateGrammarSpecs() void {
    inline for (grammar_specs, 0..) |spec, spec_index| {
        if (spec.package_index >= package_specs.len) {
            @compileError(std.fmt.comptimePrint(
                "grammar_specs[{d}] references missing package index {d}",
                .{ spec_index, spec.package_index },
            ));
        }

        if (spec.lib_name == null) {
            if (spec.has_scanner) {
                @compileError(std.fmt.comptimePrint(
                    "grammar_specs[{d}] cannot enable has_scanner without lib_name",
                    .{spec_index},
                ));
            }
            if (spec.src_subdir != null) {
                @compileError(std.fmt.comptimePrint(
                    "grammar_specs[{d}] cannot set src_subdir without lib_name",
                    .{spec_index},
                ));
            }
        }

        inline for (spec.query_assets, 0..) |asset, asset_index| {
            if (asset.dep_path.len == 0 or asset.output_name.len == 0 or asset.binding_name.len == 0) {
                @compileError(std.fmt.comptimePrint(
                    "grammar_specs[{d}].query_assets[{d}] must set dep_path, output_name, and binding_name",
                    .{ spec_index, asset_index },
                ));
            }

            inline for (grammar_specs, 0..) |other_spec, other_spec_index| {
                inline for (other_spec.query_assets, 0..) |other_asset, other_asset_index| {
                    if (other_spec_index < spec_index) continue;
                    if (other_spec_index == spec_index and other_asset_index <= asset_index) continue;

                    if (std.mem.eql(u8, asset.binding_name, other_asset.binding_name)) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate query asset binding '{s}' in grammar_specs[{d}].query_assets[{d}] and grammar_specs[{d}].query_assets[{d}]",
                            .{ asset.binding_name, spec_index, asset_index, other_spec_index, other_asset_index },
                        ));
                    }

                    if (std.mem.eql(u8, asset.output_name, other_asset.output_name)) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate query asset output '{s}' in grammar_specs[{d}].query_assets[{d}] and grammar_specs[{d}].query_assets[{d}]",
                            .{ asset.output_name, spec_index, asset_index, other_spec_index, other_asset_index },
                        ));
                    }
                }
            }
        }

        inline for (spec.query_exports, 0..) |query_export, export_index| {
            if (query_export.name.len == 0) {
                @compileError(std.fmt.comptimePrint(
                    "grammar_specs[{d}].query_exports[{d}] must set name",
                    .{ spec_index, export_index },
                ));
            }
            if (query_export.parts.len == 0) {
                @compileError(std.fmt.comptimePrint(
                    "grammar_specs[{d}].query_exports[{d}] must include at least one part",
                    .{ spec_index, export_index },
                ));
            }

            inline for (grammar_specs) |asset_spec| {
                inline for (asset_spec.query_assets) |asset| {
                    if (std.mem.eql(u8, query_export.name, asset.binding_name)) {
                        @compileError(std.fmt.comptimePrint(
                            "query export '{s}' conflicts with asset binding '{s}'",
                            .{ query_export.name, asset.binding_name },
                        ));
                    }
                }
            }

            inline for (grammar_specs, 0..) |other_spec, other_spec_index| {
                inline for (other_spec.query_exports, 0..) |other_export, other_export_index| {
                    if (other_spec_index < spec_index) continue;
                    if (other_spec_index == spec_index and other_export_index <= export_index) continue;

                    if (std.mem.eql(u8, query_export.name, other_export.name)) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate query export '{s}' in grammar_specs[{d}].query_exports[{d}] and grammar_specs[{d}].query_exports[{d}]",
                            .{ query_export.name, spec_index, export_index, other_spec_index, other_export_index },
                        ));
                    }
                }
            }

            inline for (query_export.parts, 0..) |part, part_index| {
                if (part.len == 0) {
                    @compileError(std.fmt.comptimePrint(
                        "grammar_specs[{d}].query_exports[{d}].parts[{d}] must not be empty",
                        .{ spec_index, export_index, part_index },
                    ));
                }
                if (!queryAssetBindingExists(part)) {
                    @compileError(std.fmt.comptimePrint(
                        "query export '{s}' references unknown asset binding '{s}'",
                        .{ query_export.name, part },
                    ));
                }
            }
        }
    }
}

comptime {
    @setEvalBranchQuota(10_000);
    validateGrammarSpecs();
}

fn compiledGrammarCount() comptime_int {
    var count: comptime_int = 0;
    inline for (grammar_specs) |spec| {
        if (spec.lib_name != null) count += 1;
    }
    return count;
}

const zig_package_index = packageIndexByModuleName("tree-sitter-zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ts_deps = loadTreeSitterDependencies(b, target, optimize);
    const ts_support = prepareTreeSitterSupport(b, target, optimize, ts_deps);

    const source_mod = createModule(b, "src/source.zig", target, optimize);
    const memory_policy_mod = createModule(b, "src/memory_policy.zig", target, optimize);
    const bench_support_mod = createModule(b, "bench/bench_support.zig", target, optimize);
    const bench_fixtures_mod = createModule(b, "bench/fixtures.zig", target, optimize);

    const mermaid_mod = createModule(b, "src/mermaid.zig", target, optimize);
    mermaid_mod.addImport("source", source_mod);

    // Internal aggregation module exposing parse/render/source_loader/term
    // plus the public `facade` (src/lib.zig) for bench harnesses and
    // integration tests. External callers still use the facade directly
    // via src/lib.zig; the re-export here only lets tests exercise both
    // the facade contract and lower-level helpers from a single module.
    const internals_mod = createTreeSitterModule(b, "src/internals.zig", target, optimize, ts_support);
    internals_mod.addImport("memory_policy", memory_policy_mod);
    internals_mod.addImport("source", source_mod);

    const exe = addMpExecutable(b, "mp", target, optimize, source_mod, memory_policy_mod, ts_support);
    b.installArtifact(exe);

    const benches = addBenchExecutables(b, target, optimize, .{
        .fixtures = bench_fixtures_mod,
        .mermaid = mermaid_mod,
        .internals = internals_mod,
    });

    addArtifactRunStep(b, "run", "Run the app", exe, .{
        .depend_on_install = true,
        .forward_build_args = true,
    });
    addBenchSteps(b, benches);
    addTestStep(b, target, optimize, source_mod, memory_policy_mod, bench_support_mod, internals_mod, ts_support, benches);
}

const BenchModules = struct {
    fixtures: *std.Build.Module,
    mermaid: *std.Build.Module,
    internals: *std.Build.Module,
};

const BenchArtifacts = struct {
    fixtures_bench: *std.Build.Step.Compile,
    inline_bench: *std.Build.Step.Compile,
    render_bench: *std.Build.Step.Compile,
    mermaid_bench: *std.Build.Step.Compile,
    pipeline_bench: *std.Build.Step.Compile,

    fn compileTargets(self: @This()) [5]*std.Build.Step.Compile {
        return .{
            self.fixtures_bench,
            self.inline_bench,
            self.render_bench,
            self.mermaid_bench,
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
    memory_policy_mod: *std.Build.Module,
    ts_support: TreeSitterSupport,
) *std.Build.Step.Compile {
    const exe_mod = createTreeSitterModule(b, "src/main.zig", target, optimize, ts_support);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

    exe_mod.addImport("source", source_mod);
    exe_mod.addImport("memory_policy", memory_policy_mod);
    exe_mod.addOptions("build_options", build_options);
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

    const pipeline_mod = createModule(b, "bench/bench_pipeline.zig", target, optimize);
    pipeline_mod.addImport("internals", bench_modules.internals);
    pipeline_mod.addImport("fixtures", bench_modules.fixtures);

    return .{
        .fixtures_bench = addExecutableArtifact(b, "bench-fixtures", fixtures_mod),
        .inline_bench = addExecutableArtifact(b, "inline-bench", inline_mod),
        .render_bench = addExecutableArtifact(b, "render-bench", render_mod),
        .mermaid_bench = addExecutableArtifact(b, "mermaid-bench", mermaid_mod),
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
    addArtifactRunStep(b, "bench-pipeline", "Run parse + render pipeline benchmark", benches.pipeline_bench, .{
        .forward_build_args = true,
    });
}

fn addTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_mod: *std.Build.Module,
    memory_policy_mod: *std.Build.Module,
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
        test_mod.addImport("memory_policy", memory_policy_mod);
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

    addExpectedCompileErrorTest(b, test_step, target, optimize, .{
        .root_path = "test/compile_errors/env_get_contract_width.zig",
        .module_name = "width",
        .module_path = "src/term/width.zig",
        .expected_tag = env_like_contract.missing_get_diagnostic_tag,
    });
    addExpectedCompileErrorTest(b, test_step, target, optimize, .{
        .root_path = "test/compile_errors/env_get_receiver_contract_width.zig",
        .module_name = "width",
        .module_path = "src/term/width.zig",
        .expected_tag = env_like_contract.invalid_get_receiver_diagnostic_tag,
    });
    addExpectedCompileErrorTest(b, test_step, target, optimize, .{
        .root_path = "test/compile_errors/env_get_name_param_contract.zig",
        .module_name = "env_like",
        .module_path = "src/term/env_like.zig",
        .expected_tag = env_like_contract.invalid_get_name_param_diagnostic_tag,
    });
    addExpectedCompileErrorTest(b, test_step, target, optimize, .{
        .root_path = "test/compile_errors/env_get_return_type_contract.zig",
        .module_name = "env_like",
        .module_path = "src/term/env_like.zig",
        .expected_tag = env_like_contract.invalid_get_return_type_diagnostic_tag,
    });
}

const CompileErrorTestSpec = struct {
    root_path: []const u8,
    module_name: []const u8,
    module_path: []const u8,
    expected_tag: []const u8,
};

fn addExpectedCompileErrorTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spec: CompileErrorTestSpec,
) void {
    const test_mod = createModule(b, spec.root_path, target, optimize);
    test_mod.addImport(spec.module_name, createModule(b, spec.module_path, target, optimize));
    const compile_test = b.addTest(.{
        .root_module = test_mod,
    });
    compile_test.expect_errors = .{
        .contains = spec.expected_tag,
    };
    test_step.dependOn(&compile_test.step);
}

const TreeSitterDependencies = struct {
    runtime: *std.Build.Dependency,
    packages: [package_specs.len]*std.Build.Dependency,

    fn depForPackage(self: @This(), comptime index: usize) *std.Build.Dependency {
        return self.packages[index];
    }

    fn depForGrammar(self: @This(), comptime index: usize) *std.Build.Dependency {
        return self.depForPackage(grammar_specs[index].package_index);
    }
};

fn loadTreeSitterDependencies(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) TreeSitterDependencies {
    var packages: [package_specs.len]*std.Build.Dependency = undefined;
    inline for (package_specs, 0..) |spec, i| {
        packages[i] = switch (spec.dependency_style) {
            .plain => b.dependency(spec.name, .{}),
            .targeted_static => b.dependency(spec.name, .{
                .target = target,
                .optimize = optimize,
                .@"build-shared" = false,
            }),
        };
    }

    return .{
        .runtime = b.dependency("tree_sitter", .{
            .target = target,
            .optimize = optimize,
        }),
        .packages = packages,
    };
}

const GrammarLibraries = [compiledGrammarCount()]*std.Build.Step.Compile;

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
        .zig_module = deps.depForPackage(zig_package_index).module(package_specs[zig_package_index].module_name.?),
        .queries_module = createQueriesModule(b, target, optimize, deps),
        .libs = compileGrammarLibraries(b, target, optimize, deps),
    };
}

fn compileGrammarLibraries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: TreeSitterDependencies,
) GrammarLibraries {
    var libs: GrammarLibraries = undefined;
    comptime var lib_index: usize = 0;

    inline for (grammar_specs, 0..) |spec, spec_index| {
        if (spec.lib_name) |lib_name| {
            libs[lib_index] = compileGrammarLibrary(
                b,
                target,
                optimize,
                deps.depForGrammar(spec_index),
                spec,
                lib_name,
            );
            lib_index += 1;
        }
    }

    return libs;
}

fn createQueriesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: TreeSitterDependencies,
) *std.Build.Module {
    const queries = b.addWriteFiles();
    addGrammarQueries(queries, deps);
    const wrapper = queries.add("mod.zig", createQueriesWrapperSource(b));
    return b.createModule(.{
        .root_source_file = wrapper,
        .target = target,
        .optimize = optimize,
    });
}

fn addGrammarQueries(queries: anytype, deps: TreeSitterDependencies) void {
    inline for (grammar_specs, 0..) |spec, i| {
        inline for (spec.query_assets) |asset| {
            _ = queries.addCopyFile(deps.depForGrammar(i).path(asset.dep_path), asset.output_name);
        }
    }
}

fn createQueriesWrapperSource(b: *std.Build) []const u8 {
    var sink: std.Io.Writer.Allocating = .init(b.allocator);
    defer sink.deinit();

    inline for (grammar_specs) |spec| {
        inline for (spec.query_assets) |asset| {
            const visibility = if (asset.is_public) "pub " else "";
            sink.writer.print(
                "{s}const {s}: []const u8 = @embedFile(\"{s}\");\n",
                .{ visibility, asset.binding_name, asset.output_name },
            ) catch @panic("out of memory");
        }
    }

    inline for (grammar_specs) |spec| {
        inline for (spec.query_exports) |query_export| {
            const visibility = if (query_export.is_public) "pub " else "";
            sink.writer.print("{s}const {s}: []const u8 = ", .{ visibility, query_export.name }) catch @panic("out of memory");
            inline for (query_export.parts, 0..) |part, index| {
                if (index > 0) {
                    sink.writer.writeAll(" ++ \"\\n\" ++ ") catch @panic("out of memory");
                }
                sink.writer.print("{s}", .{part}) catch @panic("out of memory");
            }
            sink.writer.writeAll(";\n") catch @panic("out of memory");
        }
    }

    return b.dupe(sink.writer.buffered());
}

fn compileGrammarLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep: *std.Build.Dependency,
    spec: GrammarSpec,
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
    const subdir = spec.src_subdir orelse "src";
    const parser_path = b.fmt("{s}/parser.c", .{subdir});
    root_module.addCSourceFile(.{
        .file = dep.path(parser_path),
        .flags = &.{"-std=c11"},
    });
    if (spec.has_scanner) {
        const scanner_path = b.fmt("{s}/scanner.c", .{subdir});
        root_module.addCSourceFile(.{
            .file = dep.path(scanner_path),
            .flags = &.{"-std=c11"},
        });
    }
    root_module.addIncludePath(dep.path(subdir));
    return lib;
}

fn attachTreeSitter(module: *std.Build.Module, support: TreeSitterSupport) void {
    module.addImport("tree_sitter", support.runtime_module);
    // tree-sitter-zig is still packaged with Zig bindings upstream, so we can
    // reuse its module directly.
    module.addImport("tree-sitter-zig", support.zig_module);
    module.addImport("ts_queries", support.queries_module);
    for (support.libs) |lib| {
        module.linkLibrary(lib);
    }
}
