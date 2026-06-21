const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;

const Range = struct {
    start: Operand,
    end: Operand,
};

pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    var ranges = HashMap(Operand, Range).init(alloc);
    defer ranges.deinit();

    try rewriteFunction(&program.main, &ranges, alloc);
    for (program.functions.items) |*function| {
        ranges.clearRetainingCapacity();
        try rewriteFunction(function, &ranges, alloc);
    }
}

fn rewriteFunction(function: *Function, ranges: *HashMap(Operand, Range), alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .range => |r| {
                    try ranges.put(r.dst.operand, Range{ .start = r.start.operand, .end = r.end.operand });
                },
                .lir => |l| {
                    switch (l) {
                        .tuple_load => |tl| {
                            const lhs = ranges.get(tl.tuple.operand) orelse {
                                try new_instructions.append(alloc, instruction.*);
                                continue;
                            };
                            instruction.* = Instruction{ .lir = .{ .binop = .{
                                .dst = tl.dst,
                                .lhs = .{ .operand = lhs.start },
                                .op = .add,
                                .rhs = .{ .operand = tl.index },
                            } } };
                            try new_instructions.append(alloc, instruction.*);
                        },
                        .list_load => |tl| {
                            const lhs = ranges.get(tl.list.operand) orelse {
                                try new_instructions.append(alloc, instruction.*);
                                continue;
                            };
                            instruction.* = Instruction{ .lir = .{ .binop = .{
                                .dst = tl.dst,
                                .lhs = .{ .operand = lhs.start },
                                .op = .add,
                                .rhs = .{ .operand = tl.index },
                            } } };
                            try new_instructions.append(alloc, instruction.*);
                        },
                        else => {
                            try new_instructions.append(alloc, instruction.*);
                        },
                    }
                },
                .len => |l| {
                    const range = ranges.get(l.value.operand) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    try new_instructions.append(alloc, Instruction{ .lir = .{ .binop = .{
                        .dst = l.dst,
                        .lhs = .{ .operand = range.end },
                        .op = .sub,
                        .rhs = .{ .operand = range.start },
                    } } });
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
