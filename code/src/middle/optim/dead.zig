const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const AllocProgram = @import("common").alloc.AllocProgram;
const Operand = @import("common").alloc.Operand;
const Operands = @import("common").alloc.Operands;
const LocalId = @import("common").ir.LocalId;
const Instruction = @import("common").mir.Instruction;
const SeenValue = @import("common").ir.SeenValue;

/// run dead code elimination
pub fn run(program: *Program, alloc_program: *const AllocProgram, alloc: std.mem.Allocator) !void {
    try runFunction(&program.main, alloc_program, alloc);
    for (program.functions.items) |*function| {
        try runFunction(function, alloc_program, alloc);
    }
}

fn runFunction(function: *Function, alloc_program: *const AllocProgram, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        const instructions = block.instructions.items;
        var seen = HashMap(SeenValue, void).init(alloc);
        // seed seen with what's live from the previous block
        const alloc_block = try alloc_program.getBlockById(block.id, function.id);
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

            const defines = try instruction.getDefines();
            var uses = try instruction.getUses(alloc);

            // if operand hasn't been used yet, instruction can be removed
            if (!hasSideEffects(instruction) and defines != null and !seen.contains(defines.?)) {
                var removed = block.instructions.orderedRemove(i);
                removed.deinit(alloc);
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
        .tuple_store, .function_call, .function_return => true,
        .lir => |l| {
            return switch (l) {
                .jump,
                .branch,
                => true,
                else => false,
            };
        },
        .print,
        .phi,
        => true,
        else => false,
    };
}

test "basic block elim" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    var alloc_program = AllocProgram{ .blocks = .empty, .lines = .empty, .register_count = 1 };
    try alloc_program.blocks.append(alloc, .{
        .start = 0,
        .end = 1,
        .function_id = 0,
        .id = 0,
        .successors = .empty,
    });
    try alloc_program.lines.append(alloc, .{
        .defines = Operands.init(alloc),
        .instruction_index = 0,
        .live_out = Operands.init(alloc),
        .move = false,
        .clobber_caller_saved = false,
        .uses = Operands.init(alloc),
    });
    defer alloc_program.deinit(alloc);

    // t1 = t0
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{ .temp = .{ .id = 0, .function_id = 0 } }, .type = .any } },
    } } });
    // t2 = t0
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{ .temp = .{ .id = 0, .function_id = 0 } }, .type = .any } },
    } } });
    // print(t0)
    try instructions.append(alloc, Instruction{ .print = .{ .src = .{
        .operand = .{ .temp = .{ .id = 0, .function_id = 0 } },
        .type = .char,
    } } });

    try run(&program, &alloc_program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(1, new_instructions.len);
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .print = .{ .src = .{
        .operand = .{ .temp = .{ .id = 0, .function_id = 0 } },
        .type = .char,
    } } });
}
