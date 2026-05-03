const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.createModule(.{
        .root_source_file = b.path("src/common/ir.zig"),
        .target = target,
        .optimize = optimize,
    });

    const middle = b.addExecutable(.{
        .name = "middle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/middle/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const frontend = b.addExecutable(.{
        .name = "frontend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontend/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // import common into both
    frontend.root_module.addImport("common", common);
    middle.root_module.addImport("common", common);

    // frontend is using cypthon for the parser
    frontend.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Frameworks/Python.framework/Versions/3.13/include/python3.13" });
    frontend.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Frameworks/Python.framework/Versions/3.13/lib" });
    frontend.root_module.linkSystemLibrary("python3.13", .{});

    b.installArtifact(middle);
    b.installArtifact(frontend);

    const frontend_run = b.addRunArtifact(frontend);
    const run_frontend_step = b.step("frontend-run", "run CPython parser demo");
    run_frontend_step.dependOn(&frontend_run.step);

    // ir testing
    const middle_tests = b.addTest(.{
        .root_module = middle.root_module,
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

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(middle);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_middle_tests.step);
    test_step.dependOn(&frontend_tests.step);

    const check_step = b.step("check", "Typecheck without emitting");
    check_step.dependOn(&middle.step);
    check_step.dependOn(&frontend.step);
}
