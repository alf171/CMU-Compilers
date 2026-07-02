const std = @import("std");
const Program = @import("common").program.Program;
const ColoredGraph = @import("middle").color.ColoredGraph;
const Abi = @import("abi.zig").Abi;
const ArmAbi = @import("arm/reg.zig").ArmAbi;
const arm_emit = @import("arm/codegen.zig").emit;
const X86Abi = @import("x86/reg.zig").X86Abi;
const x86_emit = @import("x86/codegen.zig").emit;

pub const Target = union(enum) {
    ARM,
    X86,
    UNKNOWN,
};

/// the contract which each platform will need to define
pub const Platform = struct {
    abi: Abi,
    emit: *const fn (
        program: *const Program,
        colors: *const ColoredGraph,
        abi: Abi,
        alloc: std.mem.Allocator,
    ) anyerror![]u8,
};

pub fn getPlatform(target: Target) !Platform {
    return switch (target) {
        .ARM => .{
            .abi = ArmAbi,
            .emit = arm_emit,
        },
        .X86 => .{
            .abi = X86Abi,
            .emit = x86_emit,
        },
        else => error.NotImpl,
    };
}
