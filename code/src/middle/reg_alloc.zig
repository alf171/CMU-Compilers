const std = @import("std");
const ArrayList = std.ArrayList;

const common = @import("common");
const AllocProgram = common.alloc.AllocProgram;
const AllocBlock = common.alloc.AllocBlock;
const AllocLine = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const Function = common.ir.Function;
const FrontEndProgram = common.program.Program;

/// generate the necessary information such that we do register selection eventually
pub fn build(program: FrontEndProgram, reg_count: u8, alloc: std.mem.Allocator) !AllocProgram {
    var res = AllocProgram{
        .lines = .empty,
        .blocks = .empty,
        .register_count = reg_count,
    };

    var instruction_index: usize = 0;
    for (program.functions.items, 0..) |function, i| {
        try appendBlocks(function.blocks.items, &res, &instruction_index, i + 1, alloc);
    }
    try appendBlocks(program.main.blocks.items, &res, &instruction_index, 0, alloc);

    return res;
}

fn appendBlocks(
    blocks: []const common.ir.BasicBlock,
    res: *AllocProgram,
    instruction_index: *usize,
    function_id: usize,
    alloc: std.mem.Allocator,
) !void {
    var locals = std.AutoHashMap(common.ir.LocalId, common.alloc.Operand).init(alloc);
    defer locals.deinit();

    for (blocks) |block| {
        const start = res.lines.items.len;
        for (block.instructions.items) |instruction| {
            var line = AllocLine{
                .instruction_index = instruction_index.*,
                .uses = Operands.init(alloc),
                .defines = Operands.init(alloc),
                .live_out = Operands.init(alloc),
                .move = false,
                .clobber_caller_saved = false,
            };
            // set move flag and store locals for later use
            switch (instruction) {
                .lir => |lir| {
                    switch (lir) {
                        .store_local => |sl| {
                            try locals.put(sl.local.id, sl.src);
                        },
                        .load_local, .move => line.move = true,
                        else => {},
                    }
                },
                else => {},
            }
            // get defines
            const maybeDefines = try instruction.getDefines();
            if (maybeDefines) |defines| {
                switch (defines) {
                    .operand => |operand| try line.defines.ops.put(operand, {}),
                    .local => {},
                }
            }
            // get uses
            var uses = try instruction.getUses(alloc);
            defer uses.deinit(alloc);
            for (uses.items) |use| {
                switch (use) {
                    .operand => try line.uses.ops.put(use.operand, {}),
                    .local => |id| {
                        const src = locals.get(id) orelse {
                            return error.LocalNotFound;
                        };
                        try line.uses.ops.put(src, {});
                    },
                }
            }

            try res.lines.append(alloc, line);
            instruction_index.* += 1;
        }
        const end = res.lines.items.len;
        var successors = ArrayList(u32).empty;
        try successors.appendSlice(alloc, block.successors.items);

        try res.blocks.append(alloc, AllocBlock{
            .id = block.id,
            .start = start,
            .end = end,
            .successors = successors,
            .function_id = function_id,
        });
    }
}

test "lower" {
    try std.testing.expectEqual(true, true);
}
