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
pub fn lowerAlloc(program: FrontEndProgram, alloc: std.mem.Allocator) !AllocProgram {
    var res = AllocProgram{
        .lines = .empty,
        .blocks = .empty,
        .register_count = common.alloc.REG_COUNT,
    };

    var instruction_index: usize = 0;
    for (program.functions.items, 0..) |function, i| {
        try lowerBlocks(function.blocks.items, &res, &instruction_index, i + 1, alloc);
    }
    try lowerBlocks(program.main.blocks.items, &res, &instruction_index, 0, alloc);

    return res;
}

/// TODO: fetch Operands using ir method(s)
fn lowerBlocks(
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
            };

            switch (instruction) {
                .lir => |l| {
                    switch (l) {
                        .constant => |c| {
                            try line.defines.ops.put(c.dst, {});
                        },
                        .binop => |binop| {
                            try line.defines.ops.put(binop.dst, {});
                            if (binop.lhs == .operand) {
                                try line.uses.ops.put(binop.lhs.operand, {});
                            }
                            if (binop.rhs == .operand) {
                                try line.uses.ops.put(binop.rhs.operand, {});
                            }
                        },
                        .store_local => |sl| {
                            try locals.put(sl.local.id, sl.src);
                            try line.uses.ops.put(sl.src, {});
                        },
                        .load_local => |ll| {
                            const src = locals.get(ll.local.id) orelse {
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
                        .compare => |c| {
                            try line.defines.ops.put(c.dst, {});
                            try line.uses.ops.put(c.lhs, {});
                            try line.uses.ops.put(c.rhs, {});
                        },
                        .jump => {},
                        .branch => |b| {
                            try line.uses.ops.put(b.condition, {});
                        },
                        .list_literal => |al| {
                            try line.defines.ops.put(al.dst.operand, {});
                            for (al.elements) |elem| {
                                switch (elem) {
                                    .operand => |op| try line.uses.ops.put(op, {}),
                                    .constant => {},
                                }
                            }
                        },
                        .tuple_literal => |tl| {
                            try line.defines.ops.put(tl.dst.operand, {});
                            for (tl.elements) |elem| {
                                switch (elem) {
                                    .operand => |op| try line.uses.ops.put(op, {}),
                                    .constant => {},
                                }
                            }
                        },
                        .list_load => |al| {
                            try line.defines.ops.put(al.dst, {});
                            try line.uses.ops.put(al.list.operand, {});
                            try line.uses.ops.put(al.index, {});
                        },
                        .tuple_load => |tl| {
                            try line.defines.ops.put(tl.dst, {});
                            try line.uses.ops.put(tl.tuple.operand, {});
                            try line.uses.ops.put(tl.index, {});
                        },
                        .list_store => |ls| {
                            try line.uses.ops.put(ls.list.operand, {});
                            try line.uses.ops.put(ls.index, {});
                            try line.uses.ops.put(ls.src, {});
                        },
                        .tuple_store => |ts| {
                            try line.uses.ops.put(ts.tuple.operand, {});
                            try line.uses.ops.put(ts.index, {});
                            try line.uses.ops.put(ts.src, {});
                        },
                        .function_call => |fc| {
                            if (fc.dst) |dst| try line.defines.ops.put(dst, {});
                            for (fc.args) |arg| {
                                try line.uses.ops.put(arg.operand, {});
                            }
                        },
                        .function_param => |fp| {
                            try line.defines.ops.put(fp.dst.operand, {});
                        },
                        .function_return => |fr| {
                            if (fr.value) |value| {
                                try line.uses.ops.put(value, {});
                            }
                        },
                        .write => |w| {
                            try line.uses.ops.put(w.fd, {});
                            try line.uses.ops.put(w.buf.operand, {});
                            try line.uses.ops.put(w.len, {});
                        },
                        .select => |s| {
                            try line.defines.ops.put(s.dst, {});
                            try line.uses.ops.put(s.condition, {});
                            if (s.if_value == .operand) {
                                try line.uses.ops.put(s.if_value.operand, {});
                            }
                            if (s.else_value == .operand) {
                                try line.uses.ops.put(s.else_value.operand, {});
                            }
                        },
                        else => |e| {
                            std.debug.print("{s} isn't implemented\n", .{@tagName(e)});
                            return error.NotImplemented;
                        },
                    }
                },
                .print => |pi| {
                    try line.uses.ops.put(pi.src.operand, {});
                },
                .range => |r| {
                    try line.defines.ops.put(r.dst.operand, {});
                    try line.uses.ops.put(r.start.operand, {});
                    try line.uses.ops.put(r.end.operand, {});
                },
                .len => |l| {
                    try line.defines.ops.put(l.dst, {});
                    try line.uses.ops.put(l.value.operand, {});
                },
                .parallel_copy => |pc| {
                    for (pc.copies) |copy| {
                        try line.defines.ops.put(copy.dst, {});
                        try line.uses.ops.put(copy.src, {});
                    }
                },
                else => return error.NotImplemented,
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
