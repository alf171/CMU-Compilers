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
                        instruction.deinit(alloc);
                    } else {
                        try new_instructions.append(alloc, instruction.*);
                    }
                },
                .tuple_load => |tl| {
                    const scaled: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
                    // scaled = index * 8
                    const eight: TypedOperand = .{ .operand = function.nextTemp(), .type = .i64 };
                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                        .dst = eight,
                        .src = .{ .constant = .{ .i64 = 8 } },
                    } } });
                    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                        .dst = scaled,
                        .lhs = .{ .operand = tl.index, .type = .i64 },
                        .op = .mul,
                        .rhs = eight,
                    } } });
                    try new_instructions.append(alloc, .{ .lir = .{
                        .load_offset = .{
                            .dst = try tl.dst.clone(alloc),
                            .src = try tl.tuple.clone(alloc),
                            .offset = .{ .top = scaled },
                        },
                    } });
                    instruction.deinit(alloc);
                },
                .tuple_literal => |tl| {
                    try new_instructions.append(alloc, .{ .lir = .{ .stack_alloc = .{
                        .dst = try tl.dst.clone(alloc),
                        .bytes = tl.elements.len * 8,
                    } } });

                    for (tl.elements, 0..) |element, i| {
                        const src = switch (element) {
                            .constant => |c| blk: {
                                const constant: TypedOperand = .{ .operand = function.nextTemp(), .type = c.toType() };
                                try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                    .dst = constant,
                                    .src = .{ .constant = c },
                                } } });
                                break :blk constant;
                            },
                            .top => |top| top,
                        };
                        try new_instructions.append(alloc, .{ .lir = .{ .store_offset = .{
                            .dst = try tl.dst.clone(alloc),
                            .offset = .{ .constant = .{ .i64 = @intCast(i * 8) } },
                            .src = try src.clone(alloc),
                        } } });
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
