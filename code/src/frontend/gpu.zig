const std = @import("std");
const HashMap = std.AutoHashMap;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Param = @import("common").ir.Param;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const TypeInfo = @import("common").types.TypeInfo;
const ValueRef = @import("common").ir.ValueRef;

/// sets default params
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    try rewriteFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(function, alloc);
    }
}

fn rewriteFunction(
    function: *Function,
    alloc: std.mem.Allocator,
) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .gpu_launch => |gl| {
                    // emit: gpu_launch(arg_slots, arg_count, work_items, kernel_name)
                    var new_args: std.ArrayList(TypedOperand) = .empty;
                    errdefer {
                        for (new_args.items) |*arg| {
                            arg.deinit(alloc);
                        }
                        new_args.deinit(alloc);
                    }
                    {
                        var elements: std.ArrayList(ValueRef) = .empty;
                        errdefer {
                            for (elements.items) |elem| {
                                elem.deinit(alloc);
                            }
                            elements.deinit(alloc);
                        }
                        var element_types: std.ArrayList(TypeInfo) = .empty;
                        errdefer {
                            for (element_types.items) |elem| {
                                elem.deinit(alloc);
                            }
                            element_types.deinit(alloc);
                        }
                        for (gl.args) |arg| {
                            switch (arg.type) {
                                .list => {
                                    try elements.append(alloc, .{ .top = try arg.clone(alloc) });
                                    try element_types.append(alloc, try arg.type.clone(alloc));
                                    const elem_size = try (try arg.type.getElementType()).sizeOfType();
                                    // const byte_count = 8 + elem_size * elem_count;
                                    // emit instructions since elem_count is only known at runtime
                                    const elem_size_value: TypedOperand = .{
                                        .operand = function.nextTemp(),
                                        .type = .i64,
                                    };
                                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                        .dst = elem_size_value,
                                        .src = .{ .constant = .{ .i64 = @intCast(elem_size) } },
                                    } } });
                                    const elem_count: TypedOperand = .{
                                        .operand = function.nextTemp(),
                                        .type = .i64,
                                    };
                                    try new_instructions.append(alloc, .{ .len = .{
                                        .dst = elem_count,
                                        .value = try arg.clone(alloc),
                                    } });
                                    const data_bytes: TypedOperand = .{
                                        .operand = function.nextTemp(),
                                        .type = .i64,
                                    };
                                    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                                        .dst = data_bytes,
                                        .lhs = try elem_size_value.clone(alloc),
                                        .op = .mul,
                                        .rhs = try elem_count.clone(alloc),
                                    } } });
                                    const byte_count: TypedOperand = .{
                                        .operand = function.nextTemp(),
                                        .type = .i64,
                                    };
                                    const eight: TypedOperand = .{
                                        .operand = function.nextTemp(),
                                        .type = .i64,
                                    };
                                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                        .dst = eight,
                                        .src = .{ .constant = .{ .i64 = 8 } },
                                    } } });
                                    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                                        .dst = byte_count,
                                        .lhs = try data_bytes.clone(alloc),
                                        .op = .add,
                                        .rhs = eight,
                                    } } });
                                    try elements.append(alloc, .{ .top = try byte_count.clone(alloc) });
                                    try element_types.append(alloc, .i64);
                                },
                                // gpu scalars are always 8 bits wide
                                .i64, .i32 => {
                                    try elements.append(alloc, .{ .top = try arg.clone(alloc) });
                                    try elements.append(alloc, .{ .constant = .{ .i64 = 0 } });
                                    try element_types.append(alloc, .i64);
                                    try element_types.append(alloc, .i64);
                                },
                                else => |e| {
                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                    return error.NotImpl;
                                },
                            }
                        }
                        const dst: TypedOperand = .{
                            .operand = function.nextTemp(),
                            .type = .{ .tuple = .{
                                .elements = try element_types.toOwnedSlice(alloc),
                            } },
                        };
                        try new_instructions.append(alloc, .{
                            .tuple_literal = .{
                                .dst = dst,
                                .elements = try elements.toOwnedSlice(alloc),
                            },
                        });
                        try new_args.append(alloc, try dst.clone(alloc));
                    }
                    const arg_count: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .i64,
                    };
                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                        .dst = arg_count,
                        .src = .{ .constant = .{ .i64 = @intCast(gl.args.len) } },
                    } } });
                    try new_args.append(alloc, arg_count);
                    try new_args.append(alloc, try gl.work_items.clone(alloc));
                    const kernel_elements = try alloc.alloc(ValueRef, gl.kernel.len + 1);
                    const kernel_type = try alloc.alloc(TypeInfo, gl.kernel.len + 1);
                    for (gl.kernel, 0..) |ch, i| {
                        kernel_elements[i] = .{ .constant = .{ .char = ch } };
                        kernel_type[i] = .char;
                    }
                    kernel_elements[gl.kernel.len] = .{ .constant = .{ .char = 0 } };
                    kernel_type[gl.kernel.len] = .char;

                    const kernel_name: TypedOperand = .{
                        .operand = function.nextTemp(),
                        .type = .{ .tuple = .{ .elements = kernel_type } },
                    };
                    try new_args.append(alloc, kernel_name);
                    try new_instructions.append(alloc, .{
                        .tuple_literal = .{
                            .dst = try kernel_name.clone(alloc),
                            .elements = kernel_elements,
                        },
                    });
                    try new_instructions.append(alloc, .{
                        .function_call = .{
                            .dst = null,
                            .args = try new_args.toOwnedSlice(alloc),
                            .callee = .{ .direct = try alloc.dupe(u8, "gpu_launch") },
                        },
                    });

                    instruction.deinit(alloc);
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}
