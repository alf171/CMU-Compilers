const std = @import("std");
const ArrayList = std.array_list.Managed;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
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

            switch (instruction.*) {
                // naive impl: barrier needed since function param regs could be dirty
                .function_call => {
                    copyMap.clearRetainingCapacity();
                },
                .lir => |lir| switch (lir) {
                    .move => |mov| {
                        const dst = mov.dst;
                        const src = try resolve(.{ .operand = .{
                            .operand = mov.src,
                            .type = .any,
                        } }, &copyMap);
                        switch (src) {
                            .constant => try copyMap.put(dst.operand, src),
                            .operand => |op| {
                                if (!dst.operand.equal(op.operand)) {
                                    try copyMap.put(dst.operand, src);
                                }
                            },
                        }
                    },
                    .constant => |c| {
                        try copyMap.put(c.dst, .{ .constant = c.value });
                    },
                    else => {},
                },
                else => {},
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
                    c.lhs.operand = try resolveOperand(c.lhs.operand, copyMap);
                    c.rhs.operand = try resolveOperand(c.rhs.operand, copyMap);
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
        .function_call => |*fc| {
            switch (fc.callee) {
                .direct => {},
                .indirect => |*ind| {
                    ind.*.operand = try resolveOperand(ind.*.operand, copyMap);
                },
            }
            for (fc.args) |*arg| {
                arg.*.operand = try resolveOperand(arg.*.operand, copyMap);
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
        .dst = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any },
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

test "function param regs getting folded" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // TODO: t0 = 5
    // r0 = t0
    const t0: Operand = .{ .temp = .{ .id = 1, .function_id = 0 } };
    const r0: Operand = .{ .reg = .{ .id = 0, .class = .gp } };
    try instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = t0,
        .src = r0,
    } } });
    // foobar(t0)
    try instructions.append(alloc, .{
        .function_call = .{
            .dst = null,
            .callee = .{ .direct = "foobar" },
            .args = try alloc.dupe(TypedOperand, &[_]TypedOperand{.{
                .operand = t0,
                .type = .any,
            }}),
        },
    });
    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(2, new_instructions.len);
    try std.testing.expectEqualDeep(Instruction{
        .lir = .{ .move = .{ .dst = t0, .src = r0 } },
    }, new_instructions[0]);
    const call = new_instructions[1].function_call;
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualDeep(r0, call.args[0].operand);
}
