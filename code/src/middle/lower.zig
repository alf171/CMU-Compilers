const std = @import("std");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const AllocProgram = common.alloc.AllocProgram;
const AllocLine = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const FrontEndProgram = common.ir.Program;

/// generate the necessary information such that we do register selection eventually
pub fn lowerAlloc(program: FrontEndProgram, alloc: std.mem.Allocator) !AllocProgram {
    var res = AllocProgram{
        .lines = ArrayList(AllocLine).init(alloc),
        .register_count = common.alloc.REG_COUNT,
    };

    var locals = std.AutoHashMap(common.ir.LocalId, common.alloc.Operand).init(alloc);
    defer locals.deinit();

    var instruction_index: usize = 0;
    for (program.blocks.items) |block| {
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
                    try line.defines.ops.append(c.dst);
                },
                .binop => |binop| {
                    try line.defines.ops.append(binop.dst);
                    try line.uses.ops.append(binop.lhs);
                    try line.uses.ops.append(binop.rhs);
                },
                .store_local => |sl| {
                    try locals.put(sl.local, sl.src);
                    try line.uses.ops.append(sl.src);
                },
                .load_local => |ll| {
                    const src = locals.get(ll.local) orelse {
                        return error.LocalNotFound;
                    };
                    try line.defines.ops.append(ll.dst);
                    try line.uses.ops.append(src);
                    line.move = true;
                },
                .print_int => |pi| {
                    try line.uses.ops.append(pi.src);
                },
                .print_string => {},
                .compare => |c| {
                    try line.defines.ops.append(c.dst);
                    try line.uses.ops.append(c.lhs);
                    try line.uses.ops.append(c.rhs);
                },
                .jump => {},
                .branch => |b| {
                    try line.uses.ops.append(b.condition);
                },
                else => {
                    return error.NotImplemented;
                },
            }

            try res.lines.append(line);
            instruction_index += 1;
        }
    }

    return res;
}

test "lower" {
    try std.testing.expectEqual(true, true);
}
