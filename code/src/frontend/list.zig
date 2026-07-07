const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const ValueRef = @import("common").ir.ValueRef;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const getElementType = @import("common").types.getElementType;

/// calls malloc and handles layoff buisness logic like size being the first elem
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
                .list_literal => |ll| {
                    const elem_type = try getElementType(ll.dst.type);
                    const byte_count = 8 + ll.elements.len * try elem_type.sizeOfType();
                    const size_temp = function.nextTemp();
                    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                        .dst = size_temp,
                        .value = .{ .i64 = @intCast(byte_count) },
                    } } });
                    const args = try alloc.dupe(TypedOperand, &.{
                        .{ .operand = size_temp, .type = .{ .int = .i64 } },
                    });
                    try new_instructions.append(alloc, .{ .function_call = .{
                        .dst = ll.dst.operand,
                        .callee = .{ .direct = "arena_malloc" },
                        .args = args,
                    } });
                    // store list size
                    {
                        const size = function.nextTemp();
                        try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                            .dst = size,
                            .value = .{ .i64 = @intCast(ll.elements.len) },
                        } } });
                        try new_instructions.append(alloc, .{
                            .lir = .{ .list_len_set = .{
                                .list = ll.dst,
                                .len = size,
                            } },
                        });
                    }
                    // store elements
                    for (ll.elements, 0..) |elem, i| {
                        const src: ValueRef = switch (elem) {
                            .constant => |c| blk: {
                                break :blk ValueRef{ .constant = c };
                            },
                            .operand => |o| blk: {
                                const src = function.nextTemp();
                                try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                    .dst = src,
                                    .src = o.operand,
                                } } });
                                break :blk ValueRef{ .operand = .{ .operand = src, .type = .any } };
                            },
                        };
                        const index = function.nextTemp();
                        try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                            .dst = index,
                            .value = .{ .i64 = @intCast(i) },
                        } } });

                        try new_instructions.append(alloc, .{
                            .lir = .{ .list_store = .{
                                .list = ll.dst,
                                .index = index,
                                .src = src,
                            } },
                        });
                    }
                    instruction.deinit(alloc);
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}
