const std = @import("std");
const HashMap = std.AutoHashMap;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const LocalId = @import("common").ir.LocalId;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const TypeInfo = @import("common").types.TypeInfo;

const LazyKey = union(enum) {
    operand: Operand,
    local: LocalId,
};

const LazyProducers = union(enum) {
    range: struct {
        start: TypedOperand,
        end: TypedOperand,
    },
};

/// currently handles range rewrites
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    var producers = HashMap(LazyKey, LazyProducers).init(alloc);
    defer producers.deinit();

    try rewriteFunction(&program.main, &producers, alloc);
    for (program.functions.items) |*function| {
        producers.clearRetainingCapacity();
        try rewriteFunction(function, &producers, alloc);
    }
}

fn rewriteFunction(function: *Function, producers: *HashMap(LazyKey, LazyProducers), alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .range => |r| {
                    try producers.put(.{ .operand = r.dst.operand }, .{ .range = .{
                        .start = try r.start.clone(alloc),
                        .end = try r.end.clone(alloc),
                    } });
                    instruction.deinit(alloc);
                },
                .subscript => |s| {
                    if (s.src.type != .lazy) {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    }
                    const lhs = producers.get(.{ .operand = s.src.operand }) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    switch (lhs) {
                        .range => |range| {
                            try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                                .dst = s.dst,
                                .lhs = try range.start.clone(alloc),
                                .op = .add,
                                .rhs = s.index,
                            } } });
                        },
                    }
                    instruction.deinit(alloc);
                },
                .len => |l| {
                    const producer = producers.get(.{ .operand = l.value.operand }) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    switch (producer) {
                        .range => |range| {
                            try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                                .dst = l.dst,
                                .lhs = try range.end.clone(alloc),
                                .op = .sub,
                                .rhs = try range.start.clone(alloc),
                            } } });
                        },
                    }
                    instruction.deinit(alloc);
                },
                .lir => |lir| switch (lir) {
                    .store_local => |sl| {
                        if (producers.get(.{ .operand = sl.src.operand })) |producer| {
                            try producers.put(
                                .{ .local = sl.local.id },
                                producer,
                            );
                            instruction.deinit(alloc);
                            continue;
                        }
                        try new_instructions.append(alloc, instruction.*);
                    },
                    else => {
                        try new_instructions.append(alloc, instruction.*);
                    },
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
    try block0.instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = .{ .operand = start, .type = .i64 },
        .src = .{ .constant = .{ .i64 = 3 } },
    } } });
    const end = program.main.nextTemp();
    try block0.instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = .{ .operand = end, .type = .i64 },
        .src = .{ .constant = .{ .i64 = 5 } },
    } } });

    // we are hardcoding what walk.zig currently passes through here
    const range: TypedOperand = .{
        .operand = program.main.nextTemp(),
        .type = .{ .lazy = .{ .value = try TypeInfo.toOwnedPointer(.{ .iterable = .{
            .element = try TypeInfo.toOwnedPointer(.i64, alloc),
        } }, alloc) } },
    };
    try block0.instructions.append(alloc, .{
        .range = .{
            .dst = range,
            .start = .{ .operand = start, .type = .i64 },
            .end = .{ .operand = end, .type = .i64 },
        },
    });
    const n = program.main.nextTemp();
    try block0.instructions.append(alloc, .{
        .len = .{
            .dst = .{ .operand = n, .type = .i64 },
            .value = try range.clone(alloc),
        },
    });
    const i = program.main.nextTemp();
    const index: TypedOperand = .{
        .operand = program.main.nextTemp(),
        .type = .i64,
    };
    try block0.instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = index,
        .src = .{ .constant = .{ .i64 = 1 } },
    } } });
    try block0.instructions.append(alloc, .{
        .subscript = .{
            .dst = .{ .operand = i, .type = .any },
            .src = try range.clone(alloc),
            .index = try index.clone(alloc),
        },
    });
    try rewrite(&program, alloc);
    const rewritten = &program.main.blocks.items[0];
    try std.testing.expectEqual(5, rewritten.instructions.items.len);
    // start <- 3
    try std.testing.expect(rewritten.instructions.items[0].lir == .move);
    try std.testing.expect(rewritten.instructions.items[0].lir.move.src == .constant);
    // end <- 5
    try std.testing.expect(rewritten.instructions.items[1].lir == .move);
    try std.testing.expect(rewritten.instructions.items[1].lir.move.src == .constant);
    // n <- sub end, start
    try std.testing.expect(rewritten.instructions.items[2] == .lir);
    try std.testing.expect(rewritten.instructions.items[2].lir == .binop);
    try std.testing.expectEqual(.sub, rewritten.instructions.items[2].lir.binop.op);
    // index <- 1
    try std.testing.expect(rewritten.instructions.items[3] == .lir);
    try std.testing.expect(rewritten.instructions.items[3].lir == .move);
    try std.testing.expect(rewritten.instructions.items[3].lir.move.src == .constant);
    // x <- add start, index
    try std.testing.expect(rewritten.instructions.items[4] == .lir);
    try std.testing.expect(rewritten.instructions.items[4].lir == .binop);
    try std.testing.expectEqual(.add, rewritten.instructions.items[4].lir.binop.op);
}
