const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const ownedPointer = @import("common").types.ownedPointer;

const Range = struct {
    start: Operand,
    end: Operand,
};

/// currently handles range rewrites
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
                .lazy_load => |ll| {
                    const lhs = ranges.get(ll.lazy.operand) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                        .dst = ll.dst,
                        .lhs = .{ .operand = .{
                            .operand = lhs.start,
                            .type = .{ .int = .i64 },
                        } },
                        .op = .add,
                        .rhs = .{ .operand = .{
                            .operand = ll.index,
                            .type = .{ .int = .i64 },
                        } },
                    } } });
                },
                .len => |l| {
                    const range = ranges.get(l.value.operand) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    try new_instructions.append(alloc, Instruction{ .lir = .{ .binop = .{
                        .dst = l.dst,
                        .lhs = .{ .operand = .{
                            .operand = range.end,
                            .type = .{ .int = .i64 },
                        } },
                        .op = .sub,
                        .rhs = .{ .operand = .{
                            .operand = range.start,
                            .type = .{ .int = .i64 },
                        } },
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

test "range behaves lazily" {
    const alloc = std.testing.allocator;
    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    const block0 = &program.main.blocks.items[0];
    const start = program.main.nextTemp();
    try block0.instructions.append(alloc, .{ .lir = .{ .constant = .{ .dst = start, .value = .{ .i64 = 3 } } } });
    const end = program.main.nextTemp();
    try block0.instructions.append(alloc, .{ .lir = .{ .constant = .{ .dst = end, .value = .{ .i64 = 5 } } } });

    // we are hardcoding what walk.zig currently passes through here
    const range: TypedOperand = .{
        .operand = program.main.nextTemp(),
        .type = .{ .lazy = .{ .value = &.{ .iterable = .{ .element = &.{ .int = .i64 } } } } },
    };
    try block0.instructions.append(alloc, .{
        .range = .{
            .dst = range,
            .start = .{ .operand = start, .type = .{ .int = .i64 } },
            .end = .{ .operand = end, .type = .{ .int = .i64 } },
        },
    });
    const n = program.main.nextTemp();
    try block0.instructions.append(alloc, .{
        .len = .{
            .dst = n,
            .value = range,
        },
    });
    const i = program.main.nextTemp();
    const index = program.main.nextTemp();
    try block0.instructions.append(alloc, .{ .lir = .{ .constant = .{ .dst = index, .value = .{ .i64 = 1 } } } });
    try block0.instructions.append(alloc, .{
        .lazy_load = .{
            .dst = i,
            .lazy = range,
            .index = index,
        },
    });
    try rewrite(&program, alloc);
    const rewritten = &program.main.blocks.items[0];
    try std.testing.expectEqual(5, rewritten.instructions.items.len);
    // start <- 3
    try std.testing.expect(rewritten.instructions.items[0].lir == .constant);
    // end <- 5
    try std.testing.expect(rewritten.instructions.items[1].lir == .constant);
    // n <- sub end, start
    try std.testing.expect(rewritten.instructions.items[2] == .lir);
    try std.testing.expect(rewritten.instructions.items[2].lir == .binop);
    try std.testing.expectEqual(.sub, rewritten.instructions.items[2].lir.binop.op);
    // index <- 1
    try std.testing.expect(rewritten.instructions.items[3] == .lir);
    try std.testing.expect(rewritten.instructions.items[3].lir == .constant);
    // x <- add start, index
    try std.testing.expect(rewritten.instructions.items[4] == .lir);
    try std.testing.expect(rewritten.instructions.items[4].lir == .binop);
    try std.testing.expectEqual(.add, rewritten.instructions.items[4].lir.binop.op);
}
