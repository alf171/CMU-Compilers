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

            if (instruction.getDefines()) |define| {
                switch (define) {
                    .top => |top| {
                        try invalidateCopiesDependingOn(top.operand, &copyMap, alloc);
                    },
                    .local => {},
                }
            }

            switch (instruction.*) {
                // naive impl: barrier needed since function param regs could be dirty
                .function_call => {
                    copyMap.clearRetainingCapacity();
                },
                .lir => |lir| switch (lir) {
                    .move => |mov| {
                        if (mov.dst.operand == .temp) {
                            switch (mov.src) {
                                .constant => |c| {
                                    try copyMap.put(mov.dst.operand, .{ .constant = c });
                                },
                                .top => |mov_src| {
                                    const src = try resolve(.{ .top = mov_src }, &copyMap);
                                    switch (src) {
                                        .constant => try copyMap.put(mov.dst.operand, src),
                                        .top => |top| {
                                            switch (top.operand) {
                                                .reg => {},
                                                else => {
                                                    if (!mov.dst.operand.equal(top.operand)) {
                                                        try copyMap.put(mov.dst.operand, src);
                                                    }
                                                },
                                            }
                                        },
                                    }
                                },
                            }
                        }
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
                    bop.lhs.operand = try resolveOperand(bop.lhs.operand, copyMap);
                    bop.rhs.operand = try resolveOperand(bop.rhs.operand, copyMap);
                },
                .compare => |*c| {
                    c.lhs.operand = try resolveOperand(c.lhs.operand, copyMap);
                    c.rhs.operand = try resolveOperand(c.rhs.operand, copyMap);
                },
                .move => |*m| {
                    m.src = try resolve(m.src, copyMap);
                },
                .unaryop => |*uo| {
                    uo.src.operand = try resolveOperand(uo.src.operand, copyMap);
                },
                .branch => |*b| {
                    b.condition.operand = try resolveOperand(b.condition.operand, copyMap);
                },
                .store_local => |*sl| {
                    sl.src.operand = try resolveOperand(sl.src.operand, copyMap);
                },
                .select => |*s| {
                    s.condition.operand = try resolveOperand(s.condition.operand, copyMap);
                    s.if_value = try resolve(s.if_value, copyMap);
                    s.else_value = try resolve(s.else_value, copyMap);
                },
                else => {},
            }
        },
        .print => |*pi| {
            pi.src.operand = try resolveOperand(pi.src.operand, copyMap);
        },
        .tuple_literal => |*tl| {
            for (tl.elements) |*elem| {
                switch (elem.*) {
                    .top => |*top| top.*.operand = try resolveOperand(top.*.operand, copyMap),
                    .constant => {},
                }
            }
        },
        .tuple_load => |*tl| {
            tl.tuple.operand = try resolveOperand(tl.tuple.operand, copyMap);
            tl.index.operand = try resolveOperand(tl.index.operand, copyMap);
        },
        .list_load => |*ll| {
            ll.list.operand = try resolveOperand(ll.list.operand, copyMap);
            ll.index.operand = try resolveOperand(ll.index.operand, copyMap);
        },
        .list_literal => |*ll| {
            for (ll.elements) |*elem| {
                switch (elem.*) {
                    .top => |*top| top.*.operand = try resolveOperand(top.*.operand, copyMap),
                    .constant => {},
                }
            }
        },
        .function_call => |*fc| {
            switch (fc.callee) {
                .direct => {},
                .indirect => {},
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
            .top => |top| cur = top.operand,
            .constant => return op,
        }
    }
    return cur;
}

fn resolve(init: ValueRef, copyMap: *HashMap(Operand, ValueRef)) !ValueRef {
    if (init == .constant) return init;

    var cur: ValueRef = init;
    while (copyMap.get(cur.top.operand)) |next| {
        switch (next) {
            .top => |top| cur = .{ .top = top },
            .constant => |cur_const| return .{ .constant = cur_const },
        }
    }
    return cur;
}

fn invalidateCopiesDependingOn(operand: Operand, copyMap: *HashMap(Operand, ValueRef), alloc: std.mem.Allocator) !void {
    var removals = ArrayList(Operand).init(alloc);
    defer removals.deinit();

    var it = copyMap.iterator();
    while (it.next()) |entry| {
        const cur_op = entry.key_ptr.*;
        if (cur_op.equal(operand) or try dependsOn(entry.value_ptr.*, operand, copyMap, alloc)) {
            try removals.append(cur_op);
        }
    }

    for (removals.items) |remove| {
        _ = copyMap.remove(remove);
    }
}
fn dependsOn(value: ValueRef, operand: Operand, copyMap: *HashMap(Operand, ValueRef), alloc: std.mem.Allocator) !bool {
    var visited = HashMap(Operand, void).init(alloc);
    defer visited.deinit();
    var current = value;

    while (current == .top) {
        const current_op = current.top.operand;

        if (current_op.equal(operand)) {
            return true;
        }
        if (visited.contains(current_op)) return false;
        try visited.put(current_op, {});

        current = copyMap.get(current_op) orelse return false;
    }
    return false;
}

test "basic block copy prop" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // t1 = t0
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{ .temp = .{ .id = 0, .function_id = 0 } }, .type = .any } },
    } } });
    // t2 = t1
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any } },
    } } });
    // print(t2)
    try instructions.append(alloc, Instruction{ .print = .{ .src = .{
        .operand = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .type = .i64,
    } } });

    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);

    // t1 = t0
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{
            .temp = .{ .id = 0, .function_id = 0 },
        }, .type = .any } },
    } } });
    // t2 = t0
    try std.testing.expectEqualDeep(new_instructions[1], Instruction{ .lir = .{ .move = .{
        .dst = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any },
        .src = .{ .top = .{ .operand = .{
            .temp = .{ .id = 0, .function_id = 0 },
        }, .type = .any } },
    } } });
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[2], Instruction{ .print = .{
        .src = .{
            .operand = .{ .temp = .{ .id = 0, .function_id = 0 } },
            .type = .i64,
        },
    } });
}

test "constant arg setup gets folded into abi reg" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // t0 = 5
    // r0 = t0
    // foobar(r0)
    const t0: Operand = .{ .temp = .{ .id = 1, .function_id = 0 } };
    const r0: Operand = .{ .reg = .{ .id = 0, .class = .gp } };
    try instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = .{ .operand = t0, .type = .i64 },
        .src = .{ .constant = .{ .i64 = 5 } },
    } } });
    try instructions.append(alloc, .{ .lir = .{ .move = .{
        .dst = .{ .operand = r0, .type = .i64 },
        .src = .{ .top = .{ .operand = t0, .type = .i64 } },
    } } });
    try instructions.append(alloc, .{
        .function_call = .{
            .dst = null,
            .callee = .{ .direct = try alloc.dupe(u8, "foobar") },
            .args = try alloc.dupe(TypedOperand, &[_]TypedOperand{.{
                .operand = r0,
                .type = .i64,
            }}),
        },
    });
    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);
    try std.testing.expectEqualDeep(Instruction{
        .lir = .{ .move = .{
            .dst = .{ .operand = t0, .type = .i64 },
            .src = .{ .constant = .{ .i64 = 5 } },
        } },
    }, new_instructions[0]);
    try std.testing.expectEqualDeep(Instruction{
        .lir = .{ .move = .{
            .dst = .{ .operand = r0, .type = .i64 },
            .src = .{ .constant = .{ .i64 = 5 } },
        } },
    }, new_instructions[1]);
    const call = new_instructions[2].function_call;
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualDeep(r0, call.args[0].operand);
}

test "dont follow a redef" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    const x: TypedOperand = .{ .operand = .{ .temp = .{ .id = 0, .function_id = 0 } }, .type = .any };
    const temp: TypedOperand = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any };
    const y: TypedOperand = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any };

    // temp = x
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = temp,
        .src = .{ .top = x },
    } } });
    // x = y
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = x,
        .src = .{ .top = y },
    } } });
    // y = temp
    try instructions.append(alloc, Instruction{ .lir = .{ .move = .{
        .dst = y,
        .src = .{ .top = temp },
    } } });

    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);

    // temp = x
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .lir = .{ .move = .{
        .dst = temp,
        .src = .{ .top = x },
    } } });
    // x = y
    try std.testing.expectEqualDeep(new_instructions[1], Instruction{ .lir = .{ .move = .{
        .dst = x,
        .src = .{ .top = y },
    } } });
    // y = temp
    try std.testing.expectEqualDeep(new_instructions[2], Instruction{ .lir = .{ .move = .{
        .dst = y,
        .src = .{ .top = temp },
    } } });
}

test "dependOn handles cycles" {
    const alloc = std.testing.allocator;
    var copyMap = HashMap(Operand, ValueRef).init(alloc);
    defer copyMap.deinit();
    const x: TypedOperand = .{ .operand = .{ .temp = .{ .id = 0, .function_id = 0 } }, .type = .any };
    const y: TypedOperand = .{ .operand = .{ .temp = .{ .id = 1, .function_id = 0 } }, .type = .any };
    const z: TypedOperand = .{ .operand = .{ .temp = .{ .id = 2, .function_id = 0 } }, .type = .any };

    try copyMap.put(x.operand, .{ .top = y });
    try copyMap.put(y.operand, .{ .top = x });

    const depends = try dependsOn(.{ .top = x }, z.operand, &copyMap, alloc);
    try std.testing.expect(!depends);
}
