const std = @import("std");

const assert = std.debug.assert;

const Backend = enum {
    native,
    mock,
};

const Steps = struct {
    check: *std.Build.Step,
    ci: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_linux: *std.Build.Step,
    test_mock: *std.Build.Step,
    test_unit: *std.Build.Step,
    test_windows: *std.Build.Step,
};

const format_paths = [_][]const u8{ "build.zig", "src" };

const windows_libraries = [_][]const u8{ "gdi32", "kernel32", "user32" };

const linux_query = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
    .abi = .gnu,
};

const windows_query = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .windows,
    .abi = .gnu,
};

comptime {
    assert(format_paths.len > 0);
    assert(windows_libraries.len > 0);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const steps = Steps{
        .check = b.step("check", "Compile every artifact without running it"),
        .ci = b.step("ci", "Run formatting, compilation and every available suite"),
        .test_all = b.step("test", "Run every available suite and the formatting check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_linux = b.step("test:linux", "Run the display tests on a Linux host"),
        .test_mock = b.step("test:mock", "Run the full pipeline against the mock backend"),
        .test_unit = b.step("test:unit", "Run the colocated unit tests and the tidy law"),
        .test_windows = b.step("test:windows", "Run the layered window tests on Windows"),
    };

    const backend = b.option(Backend, "backend", "Backend selection: native or mock") orelse
        .native;

    const build_options = create_options(b, backend == .mock);
    const mock_build_options = create_options(b, true);

    const kalymma = b.addModule("kalymma", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    kalymma.addImport("build_options", build_options);

    link_platform(kalymma, target);

    add_format(b, &steps);
    add_suite(b, steps.test_unit, &steps, mock_build_options, "src/unit_tests.zig", optimize);
    add_suite(b, steps.test_mock, &steps, mock_build_options, "src/mock_tests.zig", optimize);
    add_linux_tests(b, &steps, optimize);
    add_windows_tests(b, &steps, target, optimize);
    add_cross_check(b, &steps, optimize);

    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.test_unit);
    steps.ci.dependOn(steps.test_mock);
    steps.ci.dependOn(steps.test_linux);
    steps.ci.dependOn(steps.test_windows);

    b.default_step.dependOn(steps.check);
}

fn create_options(b: *std.Build, mock: bool) *std.Build.Module {
    const options = b.addOptions();

    options.addOption([]const u8, "library", "kalymma");
    options.addOption(bool, "backend_mock", mock);

    return options.createModule();
}

fn add_format(b: *std.Build, steps: *const Steps) void {
    const fmt = b.addFmt(.{
        .paths = &format_paths,
        .check = true,
    });

    steps.test_fmt.dependOn(&fmt.step);
    steps.test_all.dependOn(&fmt.step);
}

fn add_suite(
    b: *std.Build,
    step: *std.Build.Step,
    steps: *const Steps,
    build_options: *std.Build.Module,
    root: []const u8,
    optimize: std.builtin.OptimizeMode,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options }},
    });

    link_platform(module, b.graph.host);

    const suite = b.addTest(.{
        .root_module = module,
        .filters = b.args orelse &.{},
    });

    const run = b.addRunArtifact(suite);

    run.setCwd(b.path("."));

    step.dependOn(&run.step);

    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&suite.step);
}

fn add_linux_tests(
    b: *std.Build,
    steps: *const Steps,
    optimize: std.builtin.OptimizeMode,
) void {
    const resolved = if (b.graph.host.result.os.tag == .linux)
        b.graph.host
    else
        b.resolveTargetQuery(linux_query);

    const module = b.createModule(.{
        .root_source_file = b.path("src/linux_tests.zig"),
        .target = resolved,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = create_options(b, false) }},
    });

    const suite = b.addTest(.{
        .root_module = module,
        .filters = b.args orelse &.{},
    });

    steps.check.dependOn(&suite.step);

    if (b.graph.host.result.os.tag != .linux) {
        return;
    }

    const run = b.addRunArtifact(suite);

    run.setCwd(b.path("."));

    steps.test_linux.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
}

fn add_windows_tests(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const resolved = if (target.result.os.tag == .windows)
        target
    else
        b.resolveTargetQuery(windows_query);

    const module = b.createModule(.{
        .root_source_file = b.path("src/windows_tests.zig"),
        .target = resolved,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = create_options(b, false) }},
    });

    link_platform(module, resolved);

    const suite = b.addTest(.{
        .root_module = module,
        .filters = b.args orelse &.{},
    });

    steps.check.dependOn(&suite.step);

    if (b.graph.host.result.os.tag != .windows) {
        return;
    }

    const run = b.addRunArtifact(suite);

    run.setCwd(b.path("."));

    steps.test_windows.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
}

fn add_cross_check(
    b: *std.Build,
    steps: *const Steps,
    optimize: std.builtin.OptimizeMode,
) void {
    const queries = [_]std.Target.Query{ linux_query, windows_query };

    for (queries) |query| {
        const resolved = b.resolveTargetQuery(query);

        const module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = create_options(b, false) }},
        });

        link_platform(module, resolved);

        const suite = b.addTest(.{
            .root_module = module,
        });

        steps.check.dependOn(&suite.step);
    }
}

fn link_platform(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) {
        return;
    }

    for (windows_libraries) |library| {
        module.linkSystemLibrary(library, .{});
    }
}
