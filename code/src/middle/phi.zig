const std = @import("std");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const Instruction = @import("common").ir.Instruction;

pub fn eliminatePhi(program: *common.ir.Program, alloc: std.mem.Allocator) !void {
    for (program.main.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .phi => |phi| {
                    for (phi.inputs) |input| {
                        // HACK: avoid temp1 = phi(temp1, something) creating temp1 = temp1
                        if (!phi.dst.operand.equal(input.value)) {
                            const move = Instruction{ .move = .{ .dst = phi.dst.operand, .src = input.value } };
                            try insertMoveBeforeTerminator(program, input.pred, move);
                        }
                    }
                },
                else => {},
            }
        }
    }
    for (program.main.blocks.items) |*block| {
        try removePhisFromBlock(block, alloc);
    }
}

fn insertMoveBeforeTerminator(
    program: *common.ir.Program,
    pred: common.ir.BlockId,
    move: common.ir.Instruction,
) !void {
    var instructions = &program.main.blocks.items[pred].instructions;
    const len = instructions.items.len;

    if (len > 0) {
        switch (instructions.items[len - 1]) {
            .jump, .branch => {
                try instructions.insert(len - 1, move);
                return;
            },
            else => {},
        }
    }
    try instructions.append(move);
}

fn removePhisFromBlock(block: *common.ir.BasicBlock, alloc: std.mem.Allocator) !void {
    var new_instructions = ArrayList(Instruction).init(alloc);
    errdefer new_instructions.deinit();
    for (block.instructions.items) |instruction| {
        switch (instruction) {
            .phi => {},
            else => |ins| try new_instructions.append(ins),
        }
    }

    block.instructions.deinit();
    block.instructions = new_instructions;
}

test "lower" {
    try std.testing.expectEqual(true, true);
}
