const std = @import("std");
const ArrayList = std.array_list.Managed;
const HashMap = std.AutoHashMap;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Program = @import("common").ir.Program;
const Operand = @import("common").alloc.Operand;
const LocalId = @import("common").ir.LocalId;
const Instruction = @import("common").ir.Instruction;

const SeenValue = union(enum) { operand: Operand, local: LocalId };

/// run dead code elimination
pub fn run(program: *Program, alloc: std.mem.Allocator) !void {
    for (program.blocks.items) |*block| {
        const instructions = block.instructions.items;
        var seen = HashMap(SeenValue, void).init(alloc);
        defer seen.deinit();
        var i: usize = block.instructions.items.len;
        while (i > 0) {
            i -= 1;
            const instruction = instructions[i];

            const defines = getDefines(instruction);
            const uses = try getUses(instruction, alloc);

            // if operand hasn't been used yet, instruction can be removed
            if (!hasSideEffects(instruction) and defines != null and !seen.contains(defines.?)) {
                _ = block.instructions.orderedRemove(i);
                alloc.free(uses);
                continue;
            }

            // once we define a value, it is longer seen so not a can be optimistically deregistered
            if (defines) |d| _ = seen.remove(d);

            // we've already seen this operand being used
            for (uses) |use| try seen.put(use, {});
            alloc.free(uses);
        }
        seen.clearRetainingCapacity();
    }
}

fn getDefines(instruction: Instruction) ?SeenValue {
    return switch (instruction) {
        .store_local => |sl| .{ .local = sl.local.id },
        .load_local => |ll| .{ .operand = ll.dst },
        .constant => |c| .{ .operand = c.dst },
        .binop => |bop| .{ .operand = bop.dst },
        .move => |m| .{ .operand = m.dst },
        .unaryop => |uop| .{ .operand = uop.dst },
        .compare => |c| .{ .operand = c.dst },
        .phi => |pi| .{ .operand = pi.dst.operand },
        .array_literal => |al| .{ .operand = al.dst },
        .array_load => |al| .{ .operand = al.dst },
        else => null,
    };
}

fn getUses(instruction: Instruction, alloc: std.mem.Allocator) ![]SeenValue {
    var res = ArrayList(SeenValue).init(alloc);
    errdefer res.deinit();

    switch (instruction) {
        .store_local => |sl| {
            const val = SeenValue{ .operand = sl.src };
            try res.append(val);
        },
        .load_local => |ll| {
            const val = SeenValue{ .local = ll.local.id };
            try res.append(val);
        },
        .binop => |bop| {
            const lhs = SeenValue{ .operand = bop.lhs };
            try res.append(lhs);
            const rhs = SeenValue{ .operand = bop.rhs };
            try res.append(rhs);
        },
        .move => |m| {
            const val = SeenValue{ .operand = m.src };
            try res.append(val);
        },
        .unaryop => |uop| {
            const val = SeenValue{ .operand = uop.src };
            try res.append(val);
        },
        .compare => |c| {
            const lhs = SeenValue{ .operand = c.lhs };
            try res.append(lhs);
            const rhs = SeenValue{ .operand = c.rhs };
            try res.append(rhs);
        },
        .phi => |pi| {
            for (pi.inputs) |phi_input| {
                const val = SeenValue{ .operand = phi_input.value };
                try res.append(val);
            }
        },
        .print => |pi| {
            const val = SeenValue{ .operand = pi.src };
            try res.append(val);
        },
        .branch => |b| {
            const val = SeenValue{ .operand = b.condition };
            try res.append(val);
        },
        .array_literal => |al| {
            for (al.elements) |elem| {
                const val = SeenValue{ .operand = elem };
                try res.append(val);
            }
        },
        .array_load => |al| {
            try res.append(SeenValue{ .operand = al.array });
            try res.append(SeenValue{ .operand = al.index });
        },
        else => {},
    }
    return res.toOwnedSlice();
}

fn hasSideEffects(instruction: Instruction) bool {
    return switch (instruction) {
        .print, .jump, .branch, .phi => true,
        else => false,
    };
}

test "basic block elim" {
    const alloc = std.testing.allocator;

    var blocks = ArrayList(BasicBlock).init(alloc);

    var instructions = ArrayList(Instruction).init(alloc);

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

    const block = BasicBlock{
        .id = 0,
        .instructions = instructions,
        .successors = ArrayList(BlockId).init(alloc),
    };
    try blocks.append(block);

    var program = Program{ .blocks = blocks };
    defer program.deinit(alloc);

    try run(&program, alloc);
    const new_instructions = program.blocks.items[0].instructions.items;
    try std.testing.expectEqual(1, new_instructions.len);
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .print = .{
        .src = .{ .temp = 0 },
        .type = .char,
    } });
}
