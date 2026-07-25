const std = @import("std");
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const TypedOperand = @import("common").alloc.TypedOperand;

/// call _arena_free at the end of our main
pub fn injectCleanup(program: *Program, alloc: std.mem.Allocator) !void {
    for (program.main.blocks.items) |*block| {
        if (block.successors.items.len != 0) continue;
        try block.instructions.append(alloc, .{ .function_call = .{
            .dst = null,
            .callee = .{ .direct = try alloc.dupe(u8, "arena_free") },
            .args = try alloc.alloc(TypedOperand, 0),
        } });
    }
}
