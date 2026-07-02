const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const frontend = b.addExecutable(.{
        .name = "frontend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontend/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const backend = b.addExecutable(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backend/arm64.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const integration_test = b.addExecutable(.{
        .name = "integration_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration/run.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const snapshot_test = b.addExecutable(.{
        .name = "snapshot_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration/snap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const frontend_mod = b.createModule(.{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const middle_mod = b.createModule(.{
        .root_source_file = b.path("src/middle/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // share irs between stages
    frontend.root_module.addImport("common", common);
    frontend_mod.addImport("common", common);
    middle_mod.addImport("common", common);
    middle_mod.addImport("backend", backend_mod);
    backend.root_module.addImport("common", common);
    backend.root_module.addImport("middle", middle_mod);
    backend_mod.addImport("common", common);
    backend_mod.addImport("middle", middle_mod);

    integration_test.root_module.addImport("common", common);
    integration_test.root_module.addImport("frontend", frontend_mod);
    integration_test.root_module.addImport("middle", middle_mod);
    integration_test.root_module.addImport("backend", backend_mod);

    const python_exe = b.option(
        []const u8,
        "python-exe",
        "Python executable used to discover include and library directories",
    ) orelse "python3.13";
    const detected_python_include_dir = trim(b.run(&.{
        python_exe,
        "-c",
        "import sysconfig; print(sysconfig.get_path('include'))",
    }));
    const detected_python_lib_dir = trim(b.run(&.{
        python_exe,
        "-c",
        "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))",
    }));

    const python_include_dir = b.option(
        []const u8,
        "python-include-dir",
        "Directory containing Python.h",
    ) orelse detected_python_include_dir;
    const python_lib_dir = b.option(
        []const u8,
        "python-lib-dir",
        "Directory containing libpython",
    ) orelse detected_python_lib_dir;
    const python_lib_name = b.option(
        []const u8,
        "python-lib-name",
        "Python library name to link",
    ) orelse "python3.13";

    // frontend is using cpython for the parser
    linkPython(frontend.root_module, python_include_dir, python_lib_dir, python_lib_name);
    linkPython(frontend_mod, python_include_dir, python_lib_dir, python_lib_name);
    linkPython(integration_test.root_module, python_include_dir, python_lib_dir, python_lib_name);

    // integration test
    const run_integration_tests = b.addRunArtifact(integration_test);
    const integration_test_step = b.step("integration-test", "run integration test");
    integration_test_step.dependOn(&run_integration_tests.step);
    if (b.args) |args| run_integration_tests.addArgs(args);

    // snapshot test using integration
    const run_snapshot_tests = b.addRunArtifact(snapshot_test);
    run_snapshot_tests.addArtifactArg(integration_test);
    const snapshot_test_step = b.step("snapshot-test", "run snapshot test");
    snapshot_test_step.dependOn(&run_snapshot_tests.step);
    if (b.args) |args| run_snapshot_tests.addArgs(args);

    b.installArtifact(frontend);

    const frontend_run = b.addRunArtifact(frontend);
    const run_frontend_step = b.step("frontend-run", "run CPython parser demo");
    run_frontend_step.dependOn(&frontend_run.step);

    // ir testing
    const middle_tests = b.addTest(.{
        .root_module = middle_mod,
    });
    const run_middle_tests = b.addRunArtifact(middle_tests);
    const middle_test_step = b.step("middle-test", "Run middle end tests");
    middle_test_step.dependOn(&run_middle_tests.step);

    // ast testing
    const frontend_tests = b.addTest(.{
        .root_module = frontend.root_module,
    });
    const run_frontend_tests = b.addRunArtifact(frontend_tests);
    const frontend_test_step = b.step("frontend-test", "Run frontend tests");
    frontend_test_step.dependOn(&run_frontend_tests.step);

    // common module testing
    const common_tests = b.addTest(.{
        .root_module = common,
    });
    const run_common_tests = b.addRunArtifact(common_tests);
    const common_test_step = b.step("common-test", "Run common tests");
    common_test_step.dependOn(&run_common_tests.step);

    const backend_run = b.addRunArtifact(backend);
    const run_backend_step = b.step("backend-run", "Run backend");
    run_backend_step.dependOn(&backend_run.step);

    const run_backend_tests = b.addRunArtifact(frontend_tests);
    const backend_test_step = b.step("backend-test", "Run backend tests");
    backend_test_step.dependOn(&run_backend_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_common_tests.step);
    test_step.dependOn(&run_frontend_tests.step);
    test_step.dependOn(&run_middle_tests.step);

    const check_step = b.step("check", "Typecheck without emitting");
    check_step.dependOn(&frontend.step);
}

fn linkPython(
    module: *std.Build.Module,
    include_dir: []const u8,
    lib_dir: []const u8,
    lib_name: []const u8,
) void {
    module.link_libc = true;
    module.addIncludePath(.{ .cwd_relative = include_dir });
    module.addLibraryPath(.{ .cwd_relative = lib_dir });
    module.addRPath(.{ .cwd_relative = lib_dir });
    module.linkSystemLibrary(lib_name, .{});
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, &std.ascii.whitespace);
}
