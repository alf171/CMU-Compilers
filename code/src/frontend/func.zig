const std = @import("std");
const HashMap = std.AutoHashMap;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const FunctionCallInst = @import("common").mir.FunctionCallInst;
const FunctionCallee = @FieldType(FunctionCallInst, "callee");
const Param = @import("common").ir.Param;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const TypeInfo = @import("common").types.TypeInfo;
const ValueRef = @import("common").ir.ValueRef;

/// sets default params
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    var function_params = std.StringHashMap([]Param).init(alloc);
    defer function_params.deinit();
    for (program.functions.items) |*function| {
        try function_params.put(function.name, function.params);
    }

    try rewriteFunction(&program.main, &function_params, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(function, &function_params, alloc);
    }
}

fn rewriteFunction(
    function: *Function,
    function_params: *std.StringHashMap([]Param),
    alloc: std.mem.Allocator,
) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                // rewrite default paramater
                .function_call => |fc| {
                    const fun_name = switch (fc.callee) {
                        .direct => |name| name,
                        .indirect => {
                            try new_instructions.append(alloc, instruction.*);
                            continue;
                        },
                    };

                    const params = function_params.get(fun_name) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    // no missing args
                    if (fc.args.len >= params.len) {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    }
                    var new_args = try alloc.alloc(TypedOperand, params.len);
                    errdefer alloc.free(new_args);

                    // fill new_args
                    for (fc.args, 0..) |arg, i| {
                        new_args[i] = try arg.clone(alloc);
                    }
                    for (params[fc.args.len..], fc.args.len..) |param, i| {
                        const default = param.default orelse {
                            return error.ExpectedDefault;
                        };

                        const default_arg: TypedOperand = .{
                            .operand = function.nextTemp(),
                            .type = try default.toType().clone(alloc),
                        };

                        switch (default) {
                            .immediate => |value| {
                                try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                    .dst = try default_arg.clone(alloc),
                                    .src = .{ .constant = value },
                                } } });
                            },
                            .composite => |comp| {
                                const elements = try alloc.dupe(ValueRef, comp.elements);
                                errdefer alloc.free(elements);

                                try new_instructions.append(alloc, .{ .list_literal = .{
                                    .dst = try default_arg.clone(alloc),
                                    .elements = elements,
                                } });
                            },
                        }
                        new_args[i] = default_arg;
                    }

                    try new_instructions.append(alloc, .{ .function_call = .{
                        .dst = if (fc.dst) |dst| try dst.clone(alloc) else null,
                        .args = new_args,
                        .callee = try fc.callee.clone(alloc),
                    } });
                    instruction.deinit(alloc);
                },
                // could move into a gpu pass
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
                        const element_types: std.ArrayList(TypeInfo) = .empty;
                        for (gl.args) |arg| {
                            try elements.append(alloc, .{ .top = arg });
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
                        }
                        const dst: TypedOperand = .{
                            .operand = function.nextTemp(),
                            .type = try element_types.toOwnedSlice(alloc),
                        };
                        try new_instructions.append(alloc, .{
                            .tuple_literal = .{
                                .dst = dst,
                                .elements = try elements.toOwnedSlice(alloc),
                            },
                        });
                        try new_args.append(alloc, dst);
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
