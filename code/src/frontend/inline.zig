const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Param = @import("common").ir.Param;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const TypeInfo = @import("common").types.TypeInfo;
const ValueRef = @import("common").ir.ValueRef;

/// inline any functions annotated with @inline
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    try rewriteFunction(&program.main, &program.functions, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(function, &program.functions, alloc);
    }
}

fn rewriteFunction(
    function: *Function,
    functions: *ArrayList(Function),
    alloc: std.mem.Allocator,
) !void {
    for (function.blocks.items) |*block| {
        var new_instructions: ArrayList(Instruction) = .empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .function_call => |fc| {
                    const function_name = switch (fc.callee) {
                        .direct => |direct| direct,
                        else => {
                            try new_instructions.append(alloc, instruction.*);
                            continue;
                        },
                    };

                    const callee = findFunction(functions, function_name) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };

                    if (!callee.is_inline) {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    }
                    // reduce scope temporarily :)
                    if (callee.blocks.items.len != 1) return error.NonInlineableFunction;
                    for (callee.blocks.items) |*callee_block| {
                        for (callee_block.instructions.items) |*callee_instruction| {
                            switch (callee_instruction.*) {
                                .function_call => return error.NonInlineableFunction,
                                .lir => |lir| switch (lir) {
                                    .jump, .branch => return error.NonInlineableFunction,
                                    else => {},
                                },
                                else => {},
                            }
                        }
                    }

                    // old -> new temp
                    var operands: HashMap(Operand, Operand) = .init(alloc);
                    defer operands.deinit();

                    for (callee.blocks.items) |*callee_block| {
                        for (callee_block.instructions.items) |*callee_instruction| {
                            switch (callee_instruction.*) {
                                .function_param => |param| {
                                    try operands.put(param.dst.operand, fc.args[param.index].operand);
                                },
                                // x <- func(r0)
                                // :becomes:
                                // x <- temp<something>
                                .function_return => |ret| {
                                    const old_src = ret.value orelse continue;
                                    const dst = fc.dst orelse return error.InvalidFunction;

                                    const mapped_src = operands.get(old_src.operand) orelse {
                                        return error.InvalidFunction;
                                    };

                                    var src = try old_src.clone(alloc);
                                    src.operand = mapped_src;
                                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                        .dst = try dst.clone(alloc),
                                        .src = .{ .top = src },
                                    } } });
                                },
                                else => {
                                    var cloned = try callee_instruction.clone(alloc);

                                    var it = operands.iterator();
                                    while (it.next()) |entry| {
                                        cloned.replaceUses(entry.key_ptr.*, entry.value_ptr.*);
                                    }

                                    if (cloned.getDefines()) |define| {
                                        switch (define) {
                                            .top => |top| {
                                                const new_temp = operands.get(top.operand) orelse blk: {
                                                    const fresh = function.nextTemp();
                                                    try operands.put(top.operand, fresh);
                                                    break :blk fresh;
                                                };
                                                cloned.replaceDefines(top.operand, new_temp);
                                            },
                                            .local => {},
                                        }
                                    }
                                    try new_instructions.append(alloc, cloned);
                                },
                            }
                        }
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

// TODO: modularize this logic
fn findFunction(functions: *ArrayList(Function), function_name: []const u8) ?*Function {
    for (functions.items) |*function| {
        if (std.mem.eql(u8, function.name, function_name)) {
            return function;
        }
    }
    return null;
}
