const std = @import("std");
const Abi = @import("backend").Abi;
const IrProgram = @import("common").program.Program;
const Copy = @import("common").mir.Copy;
const Function = @import("common").ir.Function;
const TypedOperand = @import("common").alloc.TypedOperand;
const Operand = @import("common").alloc.Operand;
const Instruction = @import("common").mir.Instruction;
const IGraph = @import("igraph.zig").IGraph;

pub fn apply(ir_program: *IrProgram, abi: Abi, alloc: std.mem.Allocator) !void {
    try applyFunction(&ir_program.main, abi, alloc);
    for (ir_program.functions.items) |*function| {
        try applyFunction(function, abi, alloc);
    }
}

pub fn applyFunction(function: *Function, abi: Abi, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .function_param => |fp| {
                    const id = try abi.getIndex(fp.index);
                    try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                        .dst = fp.dst.operand,
                        .src = .{ .reg = .{ .id = id } },
                    } } });
                },
                .lir => |lir| switch (lir) {
                    .function_call => |fc| {
                        var copies = try alloc.alloc(Copy, fc.args.len);
                        var args = try alloc.alloc(TypedOperand, fc.args.len);
                        for (fc.args, 0..) |arg, i| {
                            const reg = Operand{ .reg = .{ .id = @intCast(i) } };
                            copies[i] = .{
                                .dst = reg,
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
                        // try new_instructions.append(alloc, instruction.*);
                        try new_instructions.append(alloc, .{ .lir = .{ .function_call = .{
                            .dst = fc.dst,
                            .function_name = fc.function_name,
                            .args = args,
                        } } });
                        // move into return register
                        if (fc.dst) |dst| {
                            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                .dst = dst,
                                .src = Operand{ .reg = .{ .id = 0 } },
                            } } });
                        }
                    },
                    else => try new_instructions.append(alloc, instruction.*),
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}
