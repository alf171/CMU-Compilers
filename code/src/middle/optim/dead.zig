const std = @import("std");
const ArrayList = std.array_list.Managed;
const HashMap = std.AutoHashMap;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Program = @import("common").ir.Program;
const Operand = @import("common").alloc.Operand;
const LocalId = @import("common").ir.LocalId;
const Instruction = @import("common").ir.Instruction;
const SeenValue = @import("common").ir.SeenValue;

/// run dead code elimination
pub fn run(program: *Program, alloc: std.mem.Allocator) !void {
    for (program.main.blocks.items) |*block| {
        const instructions = block.instructions.items;
        var seen = HashMap(SeenValue, void).init(alloc);
        defer seen.deinit();
        var i: usize = block.instructions.items.len;
        while (i > 0) {
            i -= 1;
            const instruction = instructions[i];

            const defines = instruction.getDefines();
            const uses = try instruction.getUses(alloc);

            // if operand hasn't been used yet, instruction can be removed
            if (!hasSideEffects(instruction) and defines != null and !seen.contains(defines.?)) {
                _ = block.instructions.orderedRemove(i);
                uses.deinit();
                continue;
            }

            // once we define a value, it is longer seen so not a can be optimistically deregistered
            if (defines) |d| _ = seen.remove(d);

            // we've already seen this operand being used
            for (uses.items) |use| try seen.put(use, {});
            uses.deinit();
        }
        seen.clearRetainingCapacity();
    }
}

fn hasSideEffects(instruction: Instruction) bool {
    return switch (instruction) {
        .print, .jump, .branch, .phi => true,
        else => false,
    };
}

test "basic block elim" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // t1 = t0
    try instructions.append(Instruction{ .move = .{
        .dst = .{ .temp = 1 },
        .src = .{ .temp = 0 },
    } });
    // t2 = t0
    try instructions.append(Instruction{ .move = .{
        .dst = .{ .temp = 2 },
        .src = .{ .temp = 0 },
    } });
    // print(t0)
    try instructions.append(Instruction{ .print = .{
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
