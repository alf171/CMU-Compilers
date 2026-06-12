const std = @import("std");
const parser = @import("parse.zig");
const live = @import("live.zig");
const ArrayList = std.ArrayList;

const common = @import("common");
const Instruction = common.ir.Instruction;
const IrProgram = common.ir.Program;
const Function = common.ir.Function;
const AllocProgram = common.alloc.AllocProgram;
const BasicBlock = common.ir.BasicBlock;
const BlockId = common.ir.BlockId;
const Block = common.alloc.AllocBlock;
const Line = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const Operand = common.alloc.Operand;

pub fn spillRegInIr(program: *IrProgram, alloc_program: *const AllocProgram, spilled: Operand, alloc: std.mem.Allocator) !void {
    const slot = alloc_program.nextMem();
    var next_temp = alloc_program.nextTemp();

    try spillRegInFunction(&program.main, 0, spilled, slot, &next_temp, alloc);

    for (program.functions.items, 0..) |*function, i| {
        try spillRegInFunction(function, i + 1, spilled, slot, &next_temp, alloc);
    }
}

fn spillRegInFunction(
    function: *Function,
    function_idx: usize,
    spilled: Operand,
    slot: u8,
    next_temp: *u8,
    alloc: std.mem.Allocator,
) !void {
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
                            const t1 = Operand{ .temp = .{ .id = next_temp.*, .function_id = function_idx } };
                            next_temp.* += 1;
                            try new_instructions.append(alloc, Instruction{ .move = .{
                                .dst = t1,
                                .src = Operand{ .mem = slot },
                            } });
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
                        const t2 = Operand{ .temp = .{
                            .id = next_temp.*,
                            .function_id = function_idx,
                        } };
                        next_temp.* += 1;
                        try instruction.replaceDefines(spilled, t2);
                        try new_instructions.append(alloc, instruction);
                        try new_instructions.append(alloc, Instruction{ .move = .{
                            .dst = Operand{ .mem = slot },
                            .src = t2,
                        } });
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

pub fn spillReg(current_program: *const AllocProgram, reg: Operand, alloc: std.mem.Allocator) !AllocProgram {
    var new_program = AllocProgram{
        .lines = .empty,
        .blocks = .empty,
        .register_count = current_program.register_count,
    };
    errdefer new_program.deinit(alloc);

    var next_temp = current_program.nextTemp();
    const memory_pointer = current_program.nextMem();

    for (current_program.blocks.items) |block| {
        const new_start = new_program.lines.items.len;
        for (current_program.lines.items[block.start..block.end]) |line| {
            try spillLine(&new_program, line, reg, memory_pointer, &next_temp, block.function_id, alloc);
        }

        var successors = ArrayList(u32).empty;
        try successors.appendSlice(alloc, block.successors.items);

        try new_program.blocks.append(alloc, .{
            .id = block.id,
            .start = new_start,
            .end = new_program.lines.items.len,
            .successors = successors,
            .function_id = block.function_id,
        });
    }

    // std.log.debug("", .{ spill_info.def, spill_info.uses });
    return new_program;
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
    memory_pointer: u8,
    next_temp: *u8,
    function_idx: usize,
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
        const p1 = Line{ .uses = try line.uses.clone(alloc), .live_out = Operands.init(alloc), .defines = temp, .instruction_index = temp_line_number, .move = line.move };
        try new_program.lines.append(alloc, p1);
        // p2: M[] <- temp_new
        var mem = Operands.init(alloc);
        try mem.ops.put(Operand{ .mem = memory_pointer }, {});
        const new_uses = try temp.clone(alloc);
        const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const new_line = Line{ .uses = new_uses, .live_out = Operands.init(alloc), .defines = mem, .instruction_index = new_line_number, .move = false };
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
            try mem.ops.put(Operand{ .mem = memory_pointer }, {});
            const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
            const new_line = Line{ .live_out = Operands.init(alloc), .defines = temp, .instruction_index = new_line_number, .move = line.move, .uses = mem };
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
            const rewritten_line = Line{ .uses = mut_uses, .defines = mut_defines, .live_out = Operands.init(alloc), .move = line.move, .instruction_index = mut_line_count };
            try new_program.lines.append(alloc, rewritten_line);

            next_temp.* += 1;
            return;
        }
    }
    // case 3: spill reg is in the live_out only
    if (line.live_out.ops.contains(reg)) {
        const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const new_line = Line{ .live_out = Operands.init(alloc), .defines = try line.defines.clone(alloc), .instruction_index = new_line_number, .move = line.move, .uses = try line.uses.clone(alloc) };
        try new_program.lines.append(alloc, new_line);
        return;
    }

    // default: just copy untouched line
    // line number needs to be recalculated at least!
    const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
    const new_line = Line{ .uses = try line.uses.clone(alloc), .defines = try line.defines.clone(alloc), .live_out = Operands.init(alloc), .move = line.move, .instruction_index = new_line_number };
    try new_program.lines.append(alloc, new_line);
}

test "spillReg basic spill of defined reg" {
    const alloc = std.testing.allocator;

    const reg = Operand{ .temp = .{ .id = 1, .function_id = 0 } };

    var defines_ops = Operands.init(alloc);
    try defines_ops.ops.put(reg, {});

    const uses_ops = Operands.init(alloc);
    const live_out_ops = Operands.init(alloc);

    const line = Line{
        .defines = defines_ops,
        .uses = uses_ops,
        .live_out = live_out_ops,
        .instruction_index = 0,
        .move = false,
    };

    var lines = ArrayList(Line).empty;
    try lines.append(alloc, line);

    var blocks = ArrayList(Block).empty;
    try blocks.append(alloc, Block{
        .id = 0,
        .function_id = 0,
        .start = 0,
        .end = lines.items.len,
        .successors = .empty,
    });

    var program = AllocProgram{
        .lines = lines,
        .register_count = 2,
        .blocks = blocks,
    };
    defer program.deinit(alloc);

    var new_prog = try spillReg(&program, reg, alloc);
    defer new_prog.deinit(alloc);

    try std.testing.expect(new_prog.nextMem() == program.nextMem() + 1);
    try std.testing.expect(new_prog.lines.items.len > 0);
}

test "spill reg function" {
    const alloc = std.testing.allocator;

    var blocks = ArrayList(BasicBlock).empty;
    var instructions = ArrayList(Instruction).empty;
    // A <- op A, B
    const A = Operand{ .temp = .{ .id = 0, .function_id = 0 } };
    const B = Operand{ .temp = .{ .id = 1, .function_id = 0 } };
    try instructions.append(alloc, Instruction{ .binop = .{ .dst = A, .lhs = A, .op = .add, .rhs = B } });
    try blocks.append(alloc, BasicBlock{
        .id = 0,
        .instructions = instructions,
        .successors = .empty,
    });
    var function = Function{
        .name = "test",
        .idx = 0,
        .blocks = blocks,
        .entry_block = 0,
        .params = &.{},
        .return_type = .int,
        .next_temp = 1,
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
    var next_temp: u8 = 2;
    try spillRegInFunction(&function, 0, A, 0, &next_temp, alloc);

    const new_instructions = function.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);
    try std.testing.expectEqualDeep(Instruction{ .move = .{
        .dst = Operand{ .temp = .{ .id = 2, .function_id = 0 } },
        .src = Operand{ .mem = 0 },
    } }, new_instructions[0]);
    try std.testing.expectEqualDeep(Instruction{ .binop = .{
        .dst = Operand{ .temp = .{ .id = 3, .function_id = 0 } },
        .lhs = Operand{ .temp = .{ .id = 2, .function_id = 0 } },
        .op = .add,
        .rhs = Operand{ .temp = .{ .id = 1, .function_id = 0 } },
    } }, new_instructions[1]);
    try std.testing.expectEqualDeep(Instruction{ .move = .{
        .dst = Operand{ .mem = 0 },
        .src = Operand{ .temp = .{ .id = 3, .function_id = 0 } },
    } }, new_instructions[2]);
}
