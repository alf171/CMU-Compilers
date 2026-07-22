const std = @import("std");
const ArrayList = std.ArrayList;

const common = @import("common");
const LocalId = common.ir.LocalId;
const AllocProgram = common.alloc.AllocProgram;
const AllocBlock = common.alloc.AllocBlock;
const AllocLine = common.alloc.AllocLine;
const RegisterOperands = common.alloc.RegisterOperands;
const Function = common.ir.Function;
const FunctionKind = common.ir.FunctionKind;
const FrontEndProgram = common.program.Program;
const TypedOperand = common.alloc.TypedOperand;

/// generate the necessary information such that we do register selection eventually
pub fn build(program: FrontEndProgram, alloc: std.mem.Allocator) !AllocProgram {
    var res = AllocProgram{
        .lines = .empty,
        .blocks = .empty,
    };

    var instruction_index: usize = 0;
    for (program.functions.items, 0..) |function, i| {
        try appendBlocks(
            function.blocks.items,
            &res,
            &instruction_index,
            i + 1,
            function.kind,
            alloc,
        );
    }
    try appendBlocks(
        program.main.blocks.items,
        &res,
        &instruction_index,
        0,
        program.main.kind,
        alloc,
    );

    return res;
}

fn appendBlocks(
    blocks: []const common.ir.BasicBlock,
    res: *AllocProgram,
    instruction_index: *usize,
    function_id: usize,
    function_kind: FunctionKind,
    alloc: std.mem.Allocator,
) !void {
    var locals = std.AutoHashMap(LocalId, TypedOperand).init(alloc);
    defer locals.deinit();

    for (blocks) |block| {
        const start = res.lines.items.len;
        for (block.instructions.items) |instruction| {
            var line = AllocLine{
                .instruction_index = instruction_index.*,
                .uses = RegisterOperands.init(alloc),
                .defines = RegisterOperands.init(alloc),
                .live_out = RegisterOperands.init(alloc),
                .move = false,
                .clobber_caller_saved = false,
            };
            // set move flag and store locals for later use
            switch (instruction) {
                // HACK: leaking MIR instruction
                // invoke a function therefore the clobber caller save registers
                .function_call => line.clobber_caller_saved = true,
                .lir => |lir| {
                    switch (lir) {
                        .store_local => |sl| {
                            try locals.put(sl.local.id, sl.src);
                        },
                        .move => |m| line.move = m.src == .top,
                        .load_local => line.move = true,
                        else => {},
                    }
                },
                else => {},
            }
            // get defines
            const maybeDefines = instruction.getDefines();
            if (maybeDefines) |defines| {
                switch (defines) {
                    .top => |top| try line.defines.ops.put(top.operand, top.type.toRegisterType(function_kind)),
                    .local => {},
                }
            }
            // get uses
            var uses = try instruction.getUses(alloc);
            defer uses.deinit(alloc);
            for (uses.items) |use| {
                switch (use) {
                    .top => |top| try line.uses.ops.put(top.operand, top.type.toRegisterType(function_kind)),
                    .local => |id| {
                        const src = locals.get(id) orelse {
                            return error.LocalNotFound;
                        };
                        try line.uses.ops.put(src.operand, src.type.toRegisterType(function_kind));
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
