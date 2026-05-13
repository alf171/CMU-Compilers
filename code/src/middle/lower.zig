const std = @import("std");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const AllocProgram = common.alloc.AllocProgram;
const AllocBlock = common.alloc.AllocBlock;
const AllocLine = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const FrontEndProgram = common.ir.Program;

/// generate the necessary information such that we do register selection eventually
pub fn lowerAlloc(program: FrontEndProgram, alloc: std.mem.Allocator) !AllocProgram {
    var res = AllocProgram{
        .lines = ArrayList(AllocLine).init(alloc),
        .blocks = ArrayList(AllocBlock).init(alloc),
        .register_count = common.alloc.REG_COUNT,
    };

    var locals = std.AutoHashMap(common.ir.LocalId, common.alloc.Operand).init(alloc);
    defer locals.deinit();

    var instruction_index: usize = 0;
    for (program.blocks.items) |block| {
        const start = res.lines.items.len;
        for (block.instructions.items) |instruction| {
            var line = AllocLine{
                .instruction_index = instruction_index,
                .uses = Operands.init(alloc),
                .defines = Operands.init(alloc),
                .live_out = Operands.init(alloc),
                .move = false,
            };

            switch (instruction) {
                .constant => |c| {
                    try line.defines.ops.put(c.dst, {});
                },
                .binop => |binop| {
                    try line.defines.ops.put(binop.dst, {});
                    try line.uses.ops.put(binop.lhs, {});
                    try line.uses.ops.put(binop.rhs, {});
                },
                .store_local => |sl| {
                    try locals.put(sl.local, sl.src);
                    try line.uses.ops.put(sl.src, {});
                },
                .load_local => |ll| {
                    const src = locals.get(ll.local) orelse {
                        return error.LocalNotFound;
                    };
                    try line.defines.ops.put(ll.dst, {});
                    try line.uses.ops.put(src, {});
                    line.move = true;
                },
                .move => |m| {
                    try line.defines.ops.put(m.dst, {});
                    try line.uses.ops.put(m.src, {});
                    line.move = true;
                },
                .print_int => |pi| {
                    try line.uses.ops.put(pi.src, {});
                },
                .print_string => {},
                .compare => |c| {
                    try line.defines.ops.put(c.dst, {});
                    try line.uses.ops.put(c.lhs, {});
                    try line.uses.ops.put(c.rhs, {});
                },
                .jump => {},
                .branch => |b| {
                    try line.uses.ops.put(b.condition, {});
                },
                else => {
                    return error.NotImplemented;
                },
            }

            try res.lines.append(line);
            instruction_index += 1;
        }
        const end = res.lines.items.len;
        var successors = ArrayList(u32).init(alloc);
        try successors.appendSlice(block.successors.items);

        try res.blocks.append(AllocBlock{
            .id = block.id,
            .start = start,
            .end = end,
            .successors = successors,
        });
    }

    return res;
}

test "lower" {
    try std.testing.expectEqual(true, true);
}
