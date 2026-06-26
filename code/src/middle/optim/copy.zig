const std = @import("std");
const ArrayList = std.array_list.Managed;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Operand = @import("common").alloc.Operand;
const ConstValue = @import("common").ir.ConstValue;
const ValueRef = @import("common").ir.ValueRef;
const Instruction = @import("common").mir.Instruction;

const HashMap = std.AutoHashMap;

pub fn run(program: *Program, alloc: std.mem.Allocator) !void {
    try runFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        try runFunction(function, alloc);
    }
}

pub fn runFunction(function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |block| {
        // copy prop will only work within a basic block
        var copyMap = HashMap(Operand, ValueRef).init(alloc);
        defer copyMap.deinit();

        for (block.instructions.items) |*instruction| {
            try rewriteUses(instruction, &copyMap);

            if (instruction.* == .lir) {
                switch (instruction.lir) {
                    .move => |mov| {
                        const dst = mov.dst;
                        const src = try resolve(.{ .operand = .{
                            .operand = mov.src,
                            .type = .any,
                        } }, &copyMap);
                        switch (src) {
                            .constant => try copyMap.put(dst, src),
                            .operand => |op| {
                                if (!dst.equal(op.operand)) {
                                    try copyMap.put(dst, src);
                                }
                            },
                        }
                    },
                    .constant => |c| {
                        try copyMap.put(c.dst, .{ .constant = c.value });
                    },
                    else => {},
                }
            }
        }
    }
}

fn rewriteUses(instruction: *Instruction, copyMap: *HashMap(Operand, ValueRef)) !void {
    switch (instruction.*) {
        .lir => |*l| {
            switch (l.*) {
                .binop => |*bop| {
                    bop.lhs = try resolve(bop.lhs, copyMap);
                    bop.rhs = try resolve(bop.rhs, copyMap);
                },
                .compare => |*c| {
                    c.lhs = try resolveOperand(c.lhs, copyMap);
                    c.rhs = try resolveOperand(c.rhs, copyMap);
                },
                .move => |*m| {
                    m.src = try resolveOperand(m.src, copyMap);
                },
                .unaryop => |*uo| {
                    uo.src = try resolveOperand(uo.src, copyMap);
                },
                .branch => |*b| {
                    b.condition = try resolveOperand(b.condition, copyMap);
                },
                .store_local => |*sl| {
                    sl.src = try resolveOperand(sl.src, copyMap);
                },
                .tuple_literal => |*tl| {
                    for (tl.elements) |*elem| {
                        switch (elem.*) {
                            .operand => |*op| op.*.operand = try resolveOperand(op.*.operand, copyMap),
                            .constant => {},
                        }
                    }
                },
                .tuple_load => |*tl| {
                    tl.tuple.operand = try resolveOperand(tl.tuple.operand, copyMap);
                    tl.index = try resolveOperand(tl.index, copyMap);
                },
                .list_load => |*ll| {
                    ll.list.operand = try resolveOperand(ll.list.operand, copyMap);
                    ll.index = try resolveOperand(ll.index, copyMap);
                },
                .tuple_store => |*ts| {
                    ts.tuple.operand = try resolveOperand(ts.tuple.operand, copyMap);
                    ts.index = try resolveOperand(ts.index, copyMap);
                    ts.src = try resolveOperand(ts.src, copyMap);
                },
                .list_store => |*ls| {
                    ls.list.operand = try resolveOperand(ls.list.operand, copyMap);
                    ls.index = try resolveOperand(ls.index, copyMap);
                    switch (ls.src) {
                        .operand => |*op| {
                            op.operand = try resolveOperand(op.operand, copyMap);
                        },
                        .constant => {},
                    }
                },
                .select => |*s| {
                    s.condition = try resolveOperand(s.condition, copyMap);
                    s.if_value = try resolve(s.if_value, copyMap);
                    s.else_value = try resolve(s.else_value, copyMap);
                },
                else => {},
            }
        },
        .print => |*pi| {
            pi.src.operand = try resolveOperand(pi.src.operand, copyMap);
        },
        .list_literal => |*ll| {
            for (ll.elements) |*elem| {
                switch (elem.*) {
                    .operand => |*op| op.*.operand = try resolveOperand(op.*.operand, copyMap),
                    .constant => {},
                }
            }
        },
        else => {},
    }
}

// this does not protect against cycles
fn resolveOperand(op: Operand, copyMap: *HashMap(Operand, ValueRef)) !Operand {
    var cur = op;
    while (copyMap.get(cur)) |next| {
        switch (next) {
            .operand => |cur_op| cur = cur_op.operand,
            .constant => return op,
        }
    }
    return cur;
}

fn resolve(init: ValueRef, copyMap: *HashMap(Operand, ValueRef)) !ValueRef {
    var cur: ValueRef = init;
    std.debug.assert(cur != .constant);
    while (copyMap.get(cur.operand.operand)) |next| {
        switch (next) {
            .operand => |cur_op| cur = .{ .operand = cur_op },
            .constant => |cur_const| return .{ .constant = cur_const },
        }
    }
    return cur;
}

test "basic block copy prop" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // t1 = t0
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = .{ .temp = .{ .id = 1, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
    } } });
    // t2 = t1
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 1, .function_id = 0 } },
    } } });
    // print(t2)
    try instructions.append(alloc, Instruction{ .print = .{ .src = .{
        .operand = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .type = .{ .int = .i64 },
    } } });

    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);

    // t1 = t0
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .lir = .{ .move = .{
        .dst = .{ .temp = .{ .id = 1, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
    } } });
    // t2 = t0
    try std.testing.expectEqualDeep(new_instructions[1], Instruction{ .lir = .{ .move = .{
        .dst = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
    } } });
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[2], Instruction{ .print = .{
        .src = .{
            .operand = .{ .temp = .{ .id = 0, .function_id = 0 } },
            .type = .{ .int = .i64 },
        },
    } });
}
