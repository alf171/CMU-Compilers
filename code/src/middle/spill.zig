const std = @import("std");
const parser = @import("parse.zig");
const live = @import("live.zig");
const ArrayList = std.ArrayList;

const common = @import("common");
const TempId = common.ir.TempId;
const MemoryId = common.ir.MemoryId;
const Instruction = common.mir.Instruction;
const IrProgram = common.program.Program;
const Function = common.ir.Function;
const Param = common.alloc.Param;
const AllocProgram = common.alloc.AllocProgram;
const BasicBlock = common.ir.BasicBlock;
const BlockId = common.ir.BlockId;
const Block = common.alloc.AllocBlock;
const Line = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const Operand = common.alloc.Operand;

// only run spill logic for the function in question since `Operand`s are function local
pub fn spillRegInIr(program: *IrProgram, spilled: Operand, alloc: std.mem.Allocator) !void {
    const spill_function_id = switch (spilled) {
        .temp => |t| t.function_id,
        else => return error.InvalidSpill,
    };
    if (program.main.id == spill_function_id) {
        try spillRegInFunction(&program.main, spilled, alloc);
    }

    for (program.functions.items) |*function| {
        if (function.id == spill_function_id) {
            try spillRegInFunction(function, spilled, alloc);
        }
    }
}

fn spillRegInFunction(
    function: *Function,
    spilled: Operand,
    alloc: std.mem.Allocator,
) !void {
    var spill_slot: ?Operand = null;
    for (function.blocks.items) |*block| {
        var new_instructions = ArrayList(Instruction).empty;
        for (block.instructions.items) |old_instruction| {
            var instruction = old_instruction;
            const maybe_defines = old_instruction.getDefines();
            var uses = try old_instruction.getUses(alloc);
            defer uses.deinit(alloc);
            for (uses.items) |use_item| {
                // :spill A:
                // A <- op A, B
                // :becomes:
                // t1 <- mem_slot
                // t2 <- op t1, B
                // mem_slot <- t2
                switch (use_item) {
                    .operand => |use_op| {
                        if (use_op.equal(spilled)) {
                            const t1 = function.nextTemp();
                            if (spill_slot == null) {
                                spill_slot = function.nextMem();
                            }
                            try new_instructions.append(alloc, Instruction{ .lir = .{ .move = .{
                                .dst = .{ .operand = t1, .type = .any },
                                .src = .{ .top = .{ .operand = spill_slot.?, .type = .any } },
                            } } });
                            instruction.replaceUses(spilled, t1);
                            continue;
                        }
                    },
                    .local => {},
                }
            }
            if (maybe_defines) |defines| switch (defines) {
                .operand => |define_op| {
                    if (define_op.equal(spilled)) {
                        const t2 = function.nextTemp();
                        try instruction.replaceDefines(spilled, t2);
                        try new_instructions.append(alloc, instruction);
                        if (spill_slot == null) {
                            spill_slot = function.nextMem();
                        }
                        try new_instructions.append(alloc, Instruction{ .lir = .{ .move = .{
                            .dst = .{ .operand = spill_slot.?, .type = .any },
                            .src = .{ .top = .{ .operand = t2, .type = .any } },
                        } } });
                        continue;
                    }
                },
                .local => {},
            };
            try new_instructions.append(alloc, instruction);
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

test "spill reg function" {
    const alloc = std.testing.allocator;

    var function = try Function.init(
        "test",
        0,
        try alloc.alloc(Param, 0),
        .i64,
        .user,
        .host,
        alloc,
    );
    defer function.deinit(alloc);
    // A <- op A, B
    const A = function.nextTemp();
    const B = function.nextTemp();
    const instruction: Instruction = .{ .lir = .{ .binop = .{
        .dst = .{ .operand = A, .type = .any },
        .lhs = .{ .operand = A, .type = .any },
        .op = .add,
        .rhs = .{ .operand = B, .type = .any },
    } } };
    try function.blocks.items[0].instructions.append(alloc, instruction);

    // :spill A:
    // :becomes:
    // t1 <- mem_slot
    // t2 <- op t1, B
    // mem_slot <- t2
    try spillRegInFunction(&function, A, alloc);

    const new_instructions = function.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);
    try std.testing.expectEqualDeep(Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{ .mem = .{ .id = 0, .function_id = 0 } }, .type = .any } },
    } } }, new_instructions[0]);
    try std.testing.expectEqualDeep(Instruction{ .lir = .{ .binop = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 3, .function_id = 0 } }, .type = .any },
        .lhs = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any },
        .op = .add,
        .rhs = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any },
    } } }, new_instructions[1]);
    try std.testing.expectEqualDeep(Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .mem = .{ .id = 0, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{ .temp = .{ .id = 3, .function_id = 0 } }, .type = .any } },
    } } }, new_instructions[2]);
}
