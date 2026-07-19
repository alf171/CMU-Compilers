const std = @import("std");
const common = @import("common");
const HashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;

const Block = common.ir.BasicBlock;
const Copy = common.mir.Copy;
const FrontEndProgram = common.program.Program;
const Function = common.ir.Function;
const Param = common.alloc.Param;
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
        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .parallel_copy => |pc| {
                    for (pc.copies) |copy| {
                        if (used.contains(copy.dst.operand)) {
                            const temp = Operand{ .temp = .{
                                .id = function.next_temp,
                                .function_id = function.id,
                            } };
                            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                .dst = .{ .operand = temp, .type = .any },
                                .src = .{ .top = try copy.dst.clone(alloc) },
                            } } });
                            try used.put(copy.dst.operand, temp);
                            function.next_temp += 1;
                            // emit the original instruction too
                            const src = if (used.get(copy.src)) |entry| entry orelse copy.src else copy.src;
                            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                .dst = try copy.dst.clone(alloc),
                                .src = .{ .top = .{ .operand = src, .type = try copy.dst.type.clone(alloc) } },
                            } } });
                        } else if (used.get(copy.src)) |entry| {
                            const temp = entry orelse copy.src;
                            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                .dst = try copy.dst.clone(alloc),
                                .src = .{ .top = .{ .operand = temp, .type = try copy.dst.type.clone(alloc) } },
                            } } });
                        } else {
                            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                .dst = try copy.dst.clone(alloc),
                                .src = .{
                                    .top = .{ .operand = copy.src, .type = try copy.dst.type.clone(alloc) },
                                },
                            } } });
                        }
                    }
                    instruction.deinit(alloc);
                },
                else => {
                    try new_instructions.append(alloc, instruction.*);
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
    var function = try Function.init(
        "test",
        0,
        try alloc.alloc(Param, 0),
        .i64,
        .user,
        .host,
        alloc,
    );

    defer function.deinit(alloc);

    const a = function.nextTemp();
    const b = function.nextTemp();
    const c = function.nextTemp();

    try function.blocks.items[0].instructions.append(alloc, Instruction{
        .parallel_copy = .{ .copies = try alloc.dupe(Copy, &.{
            Copy{ .dst = .{ .operand = a, .type = .any }, .src = b },
            Copy{ .dst = .{ .operand = b, .type = .any }, .src = c },
            Copy{ .dst = .{ .operand = c, .type = .any }, .src = a },
        }) },
    });

    var originally_defined = HashMap(Operand, void).init(alloc);
    defer originally_defined.deinit();
    for (function.blocks.items[0].instructions.items) |instruction| {
        switch (instruction) {
            .parallel_copy => |pc| {
                for (pc.copies) |copy| {
                    try originally_defined.put(copy.dst.operand, {});
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
                switch (m.src) {
                    .top => |top| {
                        if (originally_defined.contains(top.operand) and seen_defined_operands.contains(top.operand)) {
                            std.debug.print("using {} again", .{top.operand.temp});
                            return error.ValueUsedTwice;
                        }
                        try seen_defined_operands.put(m.dst.operand, {});
                    },
                    .constant => {},
                }
            },
            else => return error.UnexpectedInstruction,
        }
    }
}
