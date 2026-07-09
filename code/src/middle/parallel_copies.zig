const std = @import("std");
const common = @import("common");
const HashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;

const Block = common.ir.BasicBlock;
const Copy = common.mir.Copy;
const FrontEndProgram = common.program.Program;
const Function = common.ir.Function;
const Instruction = common.mir.Instruction;
const Operand = common.alloc.Operand;

pub fn lower(program: *FrontEndProgram, alloc: std.mem.Allocator) !void {
    try lowerFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        try lowerFunction(function, alloc);
    }
}

fn lowerFunction(function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        // used operand <- temp
        var used = HashMap(Operand, ?Operand).init(alloc);
        defer used.deinit();
        // build used
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .parallel_copy => |pc| {
                    for (pc.copies) |copy| {
                        try used.put(copy.src, null);
                    }
                },
                else => {},
            }
        }
        // perform swaps
        var new_instructions = ArrayList(Instruction).empty;
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .parallel_copy => |pc| {
                    for (pc.copies) |copy| {
                        if (used.contains(copy.dst.operand)) {
                            const temp = Operand{ .temp = .{
                                .id = function.next_temp,
                                .function_id = function.id,
                            } };
                            try new_instructions.append(alloc, Instruction{ .lir = .{ .move = .{
                                .dst = .{ .operand = temp, .type = .any },
                                .src = copy.dst.operand,
                            } } });
                            try used.put(copy.dst.operand, temp);
                            function.next_temp += 1;
                            // emit the original instruction too
                            const src = if (used.get(copy.src)) |entry| entry orelse copy.src else copy.src;
                            try new_instructions.append(alloc, Instruction{ .lir = .{ .move = .{
                                .dst = copy.dst,
                                .src = src,
                            } } });
                        } else if (used.get(copy.src)) |entry| {
                            const temp = entry orelse copy.src;
                            try new_instructions.append(alloc, Instruction{ .lir = .{ .move = .{
                                .dst = copy.dst,
                                .src = temp,
                            } } });
                        } else {
                            try new_instructions.append(alloc, Instruction{ .lir = .{ .move = .{
                                .dst = copy.dst,
                                .src = copy.src,
                            } } });
                        }
                    }
                    alloc.free(pc.copies);
                },
                else => {
                    try new_instructions.append(alloc, instruction);
                },
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

// (a, b, c) <- (b, c, a)
// seen = {}
// :becomes:
// temp_a <- a
// a <- b
// b <- c
// c <- a
test "cycle" {
    const alloc = std.testing.allocator;
    var function = Function{
        .name = "test",
        .id = 0,
        .blocks = .empty,
        .params = &.{},
        .entry_block = 0,
        .next_temp = 4,
        .next_mem = 0,
        .return_type = .{ .int = .i64 },
    };

    try function.blocks.append(alloc, Block{
        .id = 0,
        .instructions = .empty,
        .successors = .empty,
    });

    defer {
        for (function.blocks.items) |*block| {
            block.instructions.deinit(alloc);
            block.successors.deinit(alloc);
        }
        function.blocks.deinit(alloc);
    }

    const a = Operand{ .temp = .{ .id = 1, .function_id = 0 } };
    const b = Operand{ .temp = .{ .id = 2, .function_id = 0 } };
    const c = Operand{ .temp = .{ .id = 3, .function_id = 0 } };

    try function.blocks.items[0].instructions.append(alloc, Instruction{
        .parallel_copy = .{ .copies = try alloc.dupe(Copy, &.{
            Copy{ .dst = a, .src = b },
            Copy{ .dst = b, .src = c },
            Copy{ .dst = c, .src = a },
        }) },
    });

    var originally_defined = HashMap(Operand, void).init(alloc);
    defer originally_defined.deinit();
    for (function.blocks.items[0].instructions.items) |instruction| {
        switch (instruction) {
            .parallel_copy => |pc| {
                for (pc.copies) |copy| {
                    try originally_defined.put(copy.dst, {});
                }
            },
            else => return error.UnexpectedState,
        }
    }

    try lowerFunction(&function, alloc);

    var seen_defined_operands = HashMap(Operand, void).init(alloc);
    defer seen_defined_operands.deinit();
    const new_instructions = function.blocks.items[0].instructions;
    // optimally would be 4 but adds more complexity to algorithm
    // alternatively, we could handle this reduction in another pass
    try std.testing.expectEqual(6, new_instructions.items.len);
    for (new_instructions.items) |instruction| {
        try std.testing.expectEqual(.lir, std.meta.activeTag(instruction));
        switch (instruction.lir) {
            .move => |m| {
                if (originally_defined.contains(m.src) and seen_defined_operands.contains(m.src)) {
                    std.debug.print("using {} again", .{m.src.temp});
                    return error.ValueUsedTwice;
                }
                try seen_defined_operands.put(m.dst, {});
            },
            else => return error.UnexpectedInstruction,
        }
    }
}
