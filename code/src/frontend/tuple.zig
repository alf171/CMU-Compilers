const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const ValueRef = @import("common").ir.ValueRef;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const getElementType = @import("common").types.getElementType;

/// handles buisness logic of storing [size] [elements...] when consumers just see elements
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    try rewriteFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(function, alloc);
    }
}

fn rewriteFunction(function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .len => |l| {
                    if (l.value.type == .tuple) {
                        const tuple = l.value.type.tuple;
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                            .dst = l.dst,
                            .src = .{ .constant = .{ .i64 = @intCast(tuple.elements.len) } },
                        } } });
                    } else {
                        try new_instructions.append(alloc, instruction.*);
                    }
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}
