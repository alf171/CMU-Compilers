const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const ListStore = @import("common").mir.ListStore;
const ValueRef = @import("common").ir.ValueRef;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;

/// calls malloc and handles layoff buisness logic like size being the first elem
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    try rewriteFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        // skip generics looking for more generics
        // calls into generics should handle this scenario
        if (function.type_params.len > 0) continue;
        try rewriteFunction(function, alloc);
    }
}

fn rewriteFunction(function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .list_repeat => |lr| {
                    const elem_type = try lr.dst.type.getElementType();
                    const list_length_temp: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    try new_instructions.append(alloc, .{
                        .len = .{
                            .dst = list_length_temp,
                            .value = try lr.list.clone(alloc),
                        },
                    });
                    // byte_count = 8 + elem_size * list_length * repeat_count
                    const repeat_list_count: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    // repeat_list_size = list_length * repeat_count
                    try new_instructions.append(alloc, .{ .lir = .{
                        .binop = .{
                            .dst = repeat_list_count,
                            .lhs = list_length_temp,
                            .op = .mul,
                            .rhs = try lr.count.clone(alloc),
                        },
                    } });

                    // repeat_list_byte_count = repeat_list_size * elem_size
                    const elem_size: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    try new_instructions.append(alloc, .{ .lir = .{
                        .move = .{
                            .dst = elem_size,
                            .src = .{ .constant = .{ .i64 = @intCast(try elem_type.sizeOfType()) } },
                        },
                    } });
                    const repeat_list_byte_count: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    try new_instructions.append(alloc, .{ .lir = .{
                        .binop = .{
                            .dst = repeat_list_byte_count,
                            .lhs = repeat_list_count,
                            .op = .mul,
                            .rhs = elem_size,
                        },
                    } });

                    // byte_count = repeat_list_byte_count + 8
                    const byte_count: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    const eight: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    try new_instructions.append(alloc, .{ .lir = .{
                        .move = .{
                            .dst = eight,
                            .src = .{ .constant = .{ .i64 = 8 } },
                        },
                    } });
                    try new_instructions.append(alloc, .{ .lir = .{
                        .binop = .{
                            .dst = byte_count,
                            .lhs = repeat_list_byte_count,
                            .op = .add,
                            .rhs = eight,
                        },
                    } });

                    const byte_count_ref: ValueRef = .{ .top = byte_count };
                    const list_length_ref: ValueRef = .{ .top = repeat_list_count };
                    try lowerListAlloc(
                        function,
                        lr.dst,
                        byte_count_ref,
                        list_length_ref,
                        &new_instructions,
                        alloc,
                    );
                    // set repeat elements
                    const args = try alloc.alloc(TypedOperand, 3);
                    args[0] = try lr.dst.clone(alloc);
                    args[1] = try lr.list.clone(alloc);
                    args[2] = try lr.count.clone(alloc);
                    try new_instructions.append(alloc, .{ .function_call = .{
                        .dst = null,
                        .callee = .{ .direct = try alloc.dupe(u8, "list_repeat") },
                        .args = args,
                    } });
                    instruction.deinit(alloc);
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

/// calls malloc and stores size at index 0
fn lowerListAlloc(
    function: *Function,
    dst: TypedOperand,
    byte_count: ValueRef,
    list_length: ValueRef,
    new_instructions: *std.ArrayList(Instruction),
    alloc: std.mem.Allocator,
) !void {
    const size_temp = function.nextTemp();
    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = .{ .operand = size_temp, .type = .i64 },
        .src = byte_count,
    } } });
    const args = try alloc.dupe(TypedOperand, &.{
        .{ .operand = size_temp, .type = .i64 },
    });
    try new_instructions.append(alloc, .{ .function_call = .{
        .dst = try dst.clone(alloc),
        .callee = .{
            .direct = try alloc.dupe(u8, "arena_malloc"),
        },
        .args = args,
    } });
    // store list size
    {
        const src = function.nextTemp();
        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
            .dst = .{ .operand = src, .type = .i64 },
            .src = list_length,
        } } });
        try new_instructions.append(alloc, .{
            .lir = .{ .store_offset = .{
                .dst = try dst.clone(alloc),
                .offset = .{ .constant = .{ .i64 = 0 } },
                .src = .{ .operand = src, .type = .i64 },
            } },
        });
    }
}
