const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;

const common = @import("common");
const BlockId = common.ir.BlockId;
const Copy = common.ir.Copy;
const Function = common.ir.Function;
const Instruction = common.ir.Instruction;
const Program = common.ir.Program;

pub fn eliminatePhi(program: *Program, alloc: std.mem.Allocator) !void {
    try eliminatePhiInFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        try eliminatePhiInFunction(function, alloc);
    }
}

pub fn eliminatePhiInFunction(function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |block| {
        // critical edge splitting will prevent there from being many blocks feeding into a single one
        var copies_per_pred = HashMap(BlockId, ArrayList(Copy)).init(alloc);
        defer {
            var it = copies_per_pred.valueIterator();
            while (it.next()) |copies| {
                copies.deinit(alloc);
            }
            copies_per_pred.deinit();
        }
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .phi => |phi| {
                    for (phi.inputs) |input| {
                        if (phi.dst.operand.equal(input.value)) continue;
                        const entry = try copies_per_pred.getOrPut(input.pred);

                        if (!entry.found_existing) {
                            entry.value_ptr.* = ArrayList(Copy).empty;
                        }
                        try entry.value_ptr.append(alloc, .{
                            .dst = phi.dst.operand,
                            .src = input.value,
                        });
                    }
                },
                else => {},
            }
        }

        var it = copies_per_pred.iterator();
        while (it.next()) |key| {
            const copies = try key.value_ptr.toOwnedSlice(alloc);
            const instruction = Instruction{ .parallel_copy = .{
                .copies = copies,
            } };
            try insertParallelCopyBeforeTerminator(function, key.key_ptr.*, instruction, alloc);
        }
    }
    for (function.blocks.items) |*block| {
        try removePhisFromBlock(block, alloc);
    }
}

fn insertParallelCopyBeforeTerminator(
    function: *Function,
    pred: common.ir.BlockId,
    instruction: common.ir.Instruction,
    alloc: std.mem.Allocator,
) !void {
    var instructions = &function.blocks.items[pred].instructions;
    const len = instructions.items.len;

    if (len > 0) {
        switch (instructions.items[len - 1]) {
            .jump, .branch => {
                try instructions.insert(alloc, len - 1, instruction);
                return;
            },
            else => {},
        }
    }
    try instructions.append(alloc, instruction);
}

fn removePhisFromBlock(block: *common.ir.BasicBlock, alloc: std.mem.Allocator) !void {
    var new_instructions = ArrayList(Instruction).empty;
    errdefer new_instructions.deinit(alloc);
    for (block.instructions.items) |instruction| {
        switch (instruction) {
            .phi => {},
            else => |ins| try new_instructions.append(alloc, ins),
        }
    }

    block.instructions.deinit(alloc);
    block.instructions = new_instructions;
}

test "lower" {
    try std.testing.expectEqual(true, true);
}
