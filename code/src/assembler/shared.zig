const std = @import("std");
const clang = @import("clang.zig");
const elf = @import("elf.zig");
const Target = @import("backend").Target;

pub const AssemblerRequest = struct {
    // .s file
    input_file: []const u8,
    // .o file
    output_file: []const u8,
    // platform we are linking for
    target: Target,
    // optional arg if target uses HSA
    hsa_runtime_path: ?[]const u8,
};

pub const Assembler = union(enum) {
    clang,
    elf,

    // route to clang or custom assembler
    // currently owns going from asm to object file, linking malloc, and setting up hsa
    pub fn run(
        self: @This(),
        request: AssemblerRequest,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) !void {
        switch (self) {
            .clang => try clang.run(request, io, alloc),
            // TODO: rename to native
            else => try elf.run(request, io, alloc),
        }
    }
};

pub fn runCommand(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "command failed: {s}\nterm: {any}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ argv[0], result.term, result.stdout, result.stderr },
        );

        alloc.free(result.stdout);
        alloc.free(result.stderr);
        return error.CommandFailed;
    }
    return result;
}
