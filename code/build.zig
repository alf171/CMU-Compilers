const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ir/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const codegen = b.addExecutable(.{
        .name = "ast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ast/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // codegen is using cypthon for the parser
    codegen.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Frameworks/Python.framework/Versions/3.13/include/python3.13" });
    codegen.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Frameworks/Python.framework/Versions/3.13/lib" });
    codegen.root_module.linkSystemLibrary("python3.13", .{});

    b.installArtifact(exe);

    b.installArtifact(codegen);
    const codegen_run = b.addRunArtifact(codegen);
    const run_codegen_step = b.step("codegen-run", "run CPython parser demo");
    run_codegen_step.dependOn(&codegen_run.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Typecheck without emitting");
    check_step.dependOn(&exe.step);
}
