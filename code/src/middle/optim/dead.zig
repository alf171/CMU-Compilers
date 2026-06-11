const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Function = @import("common").ir.Function;
const Program = @import("common").ir.Program;
const AllocProgram = @import("common").alloc.AllocProgram;
const Operand = @import("common").alloc.Operand;
const LocalId = @import("common").ir.LocalId;
const Instruction = @import("common").ir.Instruction;
const SeenValue = @import("common").ir.SeenValue;

/// run dead code elimination
pub fn run(program: *Program, alloc_program: *const AllocProgram, alloc: std.mem.Allocator) !void {
    try runFunction(&program.main, alloc_program, alloc);
    for (program.functions.items) |*function| {
        try runFunction(function, alloc_program, alloc);
    }
}

fn runFunction(function: *Function, alloc_program: *const AllocProgram, alloc: std.mem.Allocator) !void {
    for (function.blocks.items, 0..) |*block, block_i| {
        const instructions = block.instructions.items;
        var seen = HashMap(SeenValue, void).init(alloc);
        // seed seen with what's live from the previous block
        const alloc_block = alloc_program.blocks.items[block_i];
        if (alloc_block.end != alloc_block.start) {
            const live_out = alloc_program.lines.items[alloc_block.end - 1].live_out;
            var it = live_out.ops.keyIterator();
            while (it.next()) |key| {
                try seen.put(SeenValue{
                    .operand = key.*,
                }, {});
            }
        }

        defer seen.deinit();
        var i: usize = block.instructions.items.len;
        while (i > 0) {
            i -= 1;
            const instruction = instructions[i];

            const defines = instruction.getDefines();
            var uses = try instruction.getUses(alloc);

            // if operand hasn't been used yet, instruction can be removed
            if (!hasSideEffects(instruction) and defines != null and !seen.contains(defines.?)) {
                _ = block.instructions.orderedRemove(i);
                uses.deinit(alloc);
                continue;
            }

            // once we define a value, it is longer seen so not a can be optimistically deregistered
            if (defines) |d| _ = seen.remove(d);

            // we've already seen this operand being used
            for (uses.items) |use| try seen.put(use, {});
            uses.deinit(alloc);
        }
        seen.clearRetainingCapacity();
    }
}

fn hasSideEffects(instruction: Instruction) bool {
    return switch (instruction) {
        .print,
        .jump,
        .branch,
        .phi,
        .array_store,
        .list_store,
        .function_call,
        .function_return,
        .store_local,
        => true,
        else => false,
    };
}

test "basic block elim" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // t1 = t0
    try instructions.append(alloc, Instruction{ .move = .{
        .dst = .{ .temp = 1 },
        .src = .{ .temp = 0 },
    } });
    // t2 = t0
    try instructions.append(alloc, Instruction{ .move = .{
        .dst = .{ .temp = 2 },
        .src = .{ .temp = 0 },
    } });
    // print(t0)
    try instructions.append(alloc, Instruction{ .print = .{
        .src = .{ .temp = 0 },
        .type = .char,
    } });

    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(1, new_instructions.len);
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .print = .{
        .src = .{ .temp = 0 },
        .type = .char,
    } });
}
