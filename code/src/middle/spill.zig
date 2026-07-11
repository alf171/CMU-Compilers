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
const AllocProgram = common.alloc.AllocProgram;
const BasicBlock = common.ir.BasicBlock;
const BlockId = common.ir.BlockId;
const Block = common.alloc.AllocBlock;
const Line = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const Operand = common.alloc.Operand;

pub fn spillRegInIr(program: *IrProgram, _: *const AllocProgram, spilled: Operand, alloc: std.mem.Allocator) !void {
    try spillRegInFunction(&program.main, spilled, alloc);

    for (program.functions.items) |*function| {
        try spillRegInFunction(function, spilled, alloc);
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
            const maybe_defines = try old_instruction.getDefines();
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
                                .src = spill_slot.?,
                            } } });
                            try instruction.replaceUses(spilled, t1);
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
                            .src = t2,
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

/// build a new program which spill the register provided
/// general alg:
/// 1. after def, load register into spill or memory
///   - w <- v + 3 (current line) (unchanged)
///   - M[] <- w (new line)
/// 2. before each use of register, load new temp from value in memory
///   - replace use of register with newly created temp
///   - w'' <- M[] (new_line)
///   - _ <- w'' + x (modified current line)
/// 3. edit live_out graph between steps (we could consider restoring live_out
fn spillLine(
    new_program: *AllocProgram,
    line: Line,
    reg: Operand,
    // state [start]
    memory_pointer: MemoryId,
    next_temp: *TempId,
    function_idx: usize,
    // state [end]
    alloc: std.mem.Allocator,
) !void {
    // case 1: spill reg == the register defined in the line
    // introduce another temp to reduce complexity of reusing spill_reg
    // let coalescing handle copies
    if (line.defines.ops.count() > 0 and Operand.equal(try line.defines.single(), reg)) {
        // p1: temp_new <- expr
        var temp = Operands.init(alloc);
        try temp.ops.put(Operand{ .temp = .{
            .id = next_temp.*,
            .function_id = function_idx,
        } }, {});
        const temp_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const p1 = Line{
            .uses = try line.uses.clone(alloc),
            .live_out = Operands.init(alloc),
            .defines = temp,
            .instruction_index = temp_line_number,
            .move = line.move,
            .clobber_caller_saved = line.clobber_caller_saved,
        };
        try new_program.lines.append(alloc, p1);
        // p2: M[] <- temp_new
        var mem = Operands.init(alloc);
        try mem.ops.put(Operand{ .mem = .{ .function_id = function_idx, .id = memory_pointer } }, {});
        const new_uses = try temp.clone(alloc);
        const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const new_line = Line{
            .uses = new_uses,
            .live_out = Operands.init(alloc),
            .defines = mem,
            .instruction_index = new_line_number,
            .move = false,
            .clobber_caller_saved = false,
        };
        try new_program.lines.append(alloc, new_line);
        next_temp.* += 1;
        return;
    }
    // case 2: spill reg is in use list
    var it = line.uses.ops.keyIterator();
    while (it.next()) |op| {
        if (op.*.equal(reg)) {
            // p1: temp_i <- load mem_j
            var temp = Operands.init(alloc);
            try temp.ops.put(Operand{
                .temp = .{ .id = next_temp.*, .function_id = function_idx },
            }, {});
            var mem = Operands.init(alloc);
            try mem.ops.put(Operand{ .mem = .{ .function_id = function_idx, .id = memory_pointer } }, {});
            const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
            const new_line = Line{
                .live_out = Operands.init(alloc),
                .defines = temp,
                .instruction_index = new_line_number,
                .move = line.move,
                .clobber_caller_saved = line.clobber_caller_saved,
                .uses = mem,
            };
            try new_program.lines.append(alloc, new_line);
            // p2: replace reg_{spill} with temp_i
            // std.debug.print("trying to remove {any} from line.uses: {any}", .{ reg, line.uses.ops.items });
            var mut_uses = try Operands.remove(line.uses, reg, alloc);
            try mut_uses.ops.put(Operand{ .temp = .{
                .id = next_temp.*,
                .function_id = function_idx,
            } }, {});
            const mut_defines = try line.defines.clone(alloc);
            const mut_line_count: usize = @intCast(new_program.lines.items.len + 1);
            const rewritten_line = Line{
                .uses = mut_uses,
                .defines = mut_defines,
                .live_out = Operands.init(alloc),
                .move = line.move,
                .clobber_caller_saved = line.clobber_caller_saved,
                .instruction_index = mut_line_count,
            };
            try new_program.lines.append(alloc, rewritten_line);

            next_temp.* += 1;
            return;
        }
    }
    // case 3: spill reg is in the live_out only
    if (line.live_out.ops.contains(reg)) {
        const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const new_line = Line{
            .live_out = Operands.init(alloc),
            .defines = try line.defines.clone(alloc),
            .instruction_index = new_line_number,
            .move = line.move,
            .clobber_caller_saved = line.clobber_caller_saved,
            .uses = try line.uses.clone(alloc),
        };
        try new_program.lines.append(alloc, new_line);
        return;
    }

    // default: just copy untouched line
    // line number needs to be recalculated at least!
    const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
    const new_line = Line{
        .uses = try line.uses.clone(alloc),
        .defines = try line.defines.clone(alloc),
        .live_out = Operands.init(alloc),
        .move = line.move,
        .clobber_caller_saved = line.clobber_caller_saved,
        .instruction_index = new_line_number,
    };
    try new_program.lines.append(alloc, new_line);
}

test "spill reg function" {
    const alloc = std.testing.allocator;

    var blocks = ArrayList(BasicBlock).empty;
    var instructions = ArrayList(Instruction).empty;
    // A <- op A, B
    const A = Operand{ .temp = .{ .id = 0, .function_id = 0 } };
    const B = Operand{ .temp = .{ .id = 1, .function_id = 0 } };
    try instructions.append(alloc, Instruction{ .lir = .{ .binop = .{
        .dst = .{ .operand = A, .type = .any },
        .lhs = .{ .operand = .{ .operand = A, .type = .any } },
        .op = .add,
        .rhs = .{ .operand = .{ .operand = B, .type = .any } },
    } } });
    try blocks.append(alloc, BasicBlock{
        .id = 0,
        .instructions = instructions,
        .successors = .empty,
    });
    var function = Function{
        .name = "test",
        .id = 0,
        .blocks = blocks,
        .entry_block = 0,
        .params = &.{},
        .return_type = .i64,
        .next_temp = 2,
        .next_mem = 0,
    };
    defer {
        for (blocks.items) |*block| {
            block.instructions.deinit(alloc);
            block.successors.deinit(alloc);
        }
        blocks.deinit(alloc);
    }

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
        .src = .{ .mem = .{ .id = 0, .function_id = 0 } },
    } } }, new_instructions[0]);
    try std.testing.expectEqualDeep(Instruction{ .lir = .{ .binop = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 3, .function_id = 0 } }, .type = .any },
        .lhs = .{ .operand = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any } },
        .op = .add,
        .rhs = .{ .operand = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any } },
    } } }, new_instructions[1]);
    try std.testing.expectEqualDeep(Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .mem = .{ .id = 0, .function_id = 0 } }, .type = .any },
        .src = .{ .temp = .{ .id = 3, .function_id = 0 } },
    } } }, new_instructions[2]);
}
