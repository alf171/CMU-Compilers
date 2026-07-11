const std = @import("std");
const Abi = @import("backend").Abi;
const IrProgram = @import("common").program.Program;
const Copy = @import("common").mir.Copy;
const Function = @import("common").ir.Function;
const TypedOperand = @import("common").alloc.TypedOperand;
const Operand = @import("common").alloc.Operand;
const Instruction = @import("common").mir.Instruction;
const IGraph = @import("igraph.zig").IGraph;
const PhysicalReg = @import("common").ir.PhysicalReg;

pub fn apply(ir_program: *IrProgram, abi: Abi, alloc: std.mem.Allocator) !void {
    try applyFunction(&ir_program.main, abi, alloc);
    for (ir_program.functions.items) |*function| {
        try applyFunction(function, abi, alloc);
    }
}

// FIXME: bad ownership
pub fn applyFunction(function: *Function, abi: Abi, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .function_param => |fp| {
                    const id = try abi.getIndexForType(fp.index, fp.dst.type);
                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{ .dst = fp.dst, .src = .{ .top = .{
                        .operand = .{
                            .reg = .{
                                .id = id,
                                .class = abi.regFromType(fp.dst.type),
                            },
                        },
                        .type = fp.dst.type,
                    } } } } });
                    instruction.deinit(alloc);
                },
                .function_return => |fr| {
                    if (fr.value) |src_op| {
                        const reg = Operand{ .reg = .{
                            .id = 0,
                            .class = abi.regFromType(function.return_type),
                        } };
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{ .dst = .{
                            .operand = reg,
                            .type = function.return_type,
                        }, .src = .{
                            .top = .{
                                .operand = src_op,
                                .type = function.return_type,
                            },
                        } } } });
                        // emits branch with proper coloring
                        try new_instructions.append(alloc, .{ .function_return = .{ .value = reg } });
                        instruction.deinit(alloc);
                    } else {
                        // emits branch
                        try new_instructions.append(alloc, instruction.*);
                    }
                    instruction.deinit(alloc);
                },
                .function_call => |fc| {
                    var copies = try alloc.alloc(Copy, fc.args.len);
                    // place new args to ensure proper coloring / interference
                    var args = try alloc.alloc(TypedOperand, fc.args.len);
                    for (fc.args, 0..) |arg, i| {
                        const reg = Operand{ .reg = .{
                            .id = @intCast(i),
                            .class = abi.regFromType(arg.type),
                        } };
                        copies[i] = .{
                            .dst = .{
                                .operand = reg,
                                .type = arg.type,
                            },
                            .src = arg.operand,
                        };
                        args[i] = .{
                            .operand = reg,
                            .type = arg.type,
                        };
                    }
                    try new_instructions.append(alloc, .{ .parallel_copy = .{
                        .copies = copies,
                    } });
                    // jumps to function
                    try new_instructions.append(alloc, .{ .function_call = .{
                        .dst = fc.dst,
                        .callee = fc.callee,
                        .args = args,
                    } });
                    if (fc.dst) |dst| {
                        try new_instructions.append(alloc, .{ .lir = .{
                            .move = .{
                                .dst = dst,
                                .src = .{ .top = .{
                                    .operand = .{ .reg = .{
                                        .id = abi.getFunctionReturnIdx(dst.type),
                                        .class = abi.regFromType(dst.type),
                                    } },
                                    .type = dst.type,
                                } },
                            },
                        } });
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
