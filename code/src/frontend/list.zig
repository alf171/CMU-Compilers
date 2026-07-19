const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const ListStore = @import("common").mir.ListStore;
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
                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                        .dst = .{ .operand = size_temp, .type = .i64 },
                        .src = .{ .constant = .{ .i64 = @intCast(byte_count) } },
                    } } });
                    const args = try alloc.dupe(TypedOperand, &.{
                        .{ .operand = size_temp, .type = .i64 },
                    });
                    try new_instructions.append(alloc, .{ .function_call = .{
                        .dst = try ll.dst.clone(alloc),
                        .callee = .{ .direct = try alloc.dupe(u8, "arena_malloc") },
                        .args = args,
                    } });
                    // store list size
                    {
                        const src = function.nextTemp();
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                            .dst = .{ .operand = src, .type = .i64 },
                            .src = .{ .constant = .{ .i64 = @intCast(ll.elements.len) } },
                        } } });
                        try new_instructions.append(alloc, .{
                            .lir = .{ .store_offset = .{
                                .dst = try ll.dst.clone(alloc),
                                .offset = .{ .constant = .{ .i64 = 0 } },
                                .src = .{ .operand = src, .type = .i64 },
                            } },
                        });
                    }
                    // store elements
                    for (ll.elements, 0..) |elem, i| {
                        const src: ValueRef = switch (elem) {
                            .constant => |c| blk: {
                                break :blk ValueRef{ .constant = c };
                            },
                            .top => |top| blk: {
                                const src: TypedOperand = .{ .operand = function.nextTemp(), .type = .any };
                                try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                    .dst = src,
                                    .src = .{ .top = try top.clone(alloc) },
                                } } });
                                break :blk ValueRef{ .top = src };
                            },
                        };
                        const index = function.nextTemp();
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                            .dst = .{ .operand = index, .type = .i64 },
                            .src = .{ .constant = .{ .i64 = @intCast(i) } },
                        } } });
                        try rewriteListStore(function, .{
                            .list = ll.dst,
                            .index = index,
                            .src = src,
                        }, &new_instructions, alloc);
                    }
                    instruction.deinit(alloc);
                },
                .list_store => |ls| {
                    try rewriteListStore(function, ls, &new_instructions, alloc);
                },
                .list_load => |ll| {
                    // dst <- list[index]
                    const scaled: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
                    const offset: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
                    const elem_type = try getElementType(ll.list.type);
                    const elem_size = try elem_type.sizeOfType();
                    // scaled = index
                    if (elem_size == 1) {
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                            .dst = scaled,
                            .src = .{ .top = .{
                                .operand = ll.index,
                                .type = scaled.type,
                            } },
                        } } });
                    }
                    // scaled = index * element_size
                    else {
                        const element_size: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                            .dst = element_size,
                            .src = .{ .constant = .{ .i64 = @intCast(elem_size) } },
                        } } });
                        try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                            .dst = scaled,
                            .op = .mul,
                            .lhs = .{ .operand = ll.index, .type = .i64 },
                            .rhs = element_size,
                        } } });
                    }
                    // offset = scaled + 8
                    const eight: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                        .dst = eight,
                        .src = .{ .constant = .{ .i64 = 8 } },
                    } } });
                    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                        .dst = offset,
                        .op = .add,
                        .lhs = scaled,
                        .rhs = eight,
                    } } });
                    try new_instructions.append(alloc, .{ .lir = .{
                        .load_offset = .{
                            .dst = try ll.dst.clone(alloc),
                            .src = try ll.list.clone(alloc),
                            .offset = .{ .top = try offset.clone(alloc) },
                        },
                    } });
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

fn rewriteListStore(
    function: *Function,
    ls: ListStore,
    new_instructions: *std.ArrayList(Instruction),
    alloc: std.mem.Allocator,
) !void {
    const scaled: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
    const offset: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
    const elem_type = try getElementType(ls.list.type);
    const elem_size = try elem_type.sizeOfType();
    // scaled = index
    if (elem_size == 1) {
        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
            .dst = scaled,
            .src = .{ .top = .{ .operand = ls.index, .type = scaled.type } },
        } } });
    }
    // scaled = index * element_size
    else {
        const element_size: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
            .dst = element_size,
            .src = .{ .constant = .{ .i64 = @intCast(elem_size) } },
        } } });
        try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
            .dst = scaled,
            .op = .mul,
            .lhs = .{ .operand = ls.index, .type = .i64 },
            .rhs = element_size,
        } } });
    }
    // offset = scaled + 8
    const eight: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = eight,
        .src = .{ .constant = .{ .i64 = 8 } },
    } } });
    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
        .dst = offset,
        .op = .add,
        .lhs = scaled,
        .rhs = eight,
    } } });

    const src = switch (ls.src) {
        .top => |top| top,
        .constant => |c| blk: {
            const tmp = function.nextTemp();
            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                .dst = .{ .operand = tmp, .type = c.toType() },
                .src = .{ .constant = c },
            } } });
            break :blk TypedOperand{ .operand = tmp, .type = elem_type };
        },
    };

    try new_instructions.append(alloc, .{ .lir = .{ .store_offset = .{
        .dst = try ls.list.clone(alloc),
        .offset = .{ .top = try offset.clone(alloc) },
        .src = try src.clone(alloc),
    } } });
}
