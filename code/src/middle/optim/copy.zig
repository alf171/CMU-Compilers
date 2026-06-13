const std = @import("std");
const ArrayList = std.array_list.Managed;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Program = @import("common").program.Program;
const Operand = @import("common").alloc.Operand;
const Instruction = @import("common").mir.Instruction;

const HashMap = std.AutoHashMap;

pub fn run(program: *Program, alloc: std.mem.Allocator) !void {
    for (program.main.blocks.items) |block| {
        // copy prop will only work within a basic block
        var copyMap = HashMap(Operand, Operand).init(alloc);
        defer copyMap.deinit();

        for (block.instructions.items) |*instruction| {
            rewriteUses(instruction, &copyMap);

            if (instruction.* == .lir) {
                if (instruction.lir == .move) {
                    const dst = instruction.lir.move.dst;
                    const src = resolve(instruction.lir.move.src, &copyMap);

                    if (!dst.equal(src)) {
                        try copyMap.put(dst, src);
                    }
                }
            }
        }
    }
}

fn rewriteUses(instruction: *Instruction, copyMap: *HashMap(Operand, Operand)) void {
    switch (instruction.*) {
        .lir => |*l| {
            switch (l.*) {
                .binop => |*bop| {
                    bop.lhs = resolve(bop.lhs, copyMap);
                    bop.rhs = resolve(bop.rhs, copyMap);
                },
                .compare => |*c| {
                    c.lhs = resolve(c.lhs, copyMap);
                    c.rhs = resolve(c.rhs, copyMap);
                },
                .move => |*m| {
                    m.src = resolve(m.src, copyMap);
                },
                .unaryop => |*uo| {
                    uo.src = resolve(uo.src, copyMap);
                },
                .branch => |*b| {
                    b.condition = resolve(b.condition, copyMap);
                },
                .store_local => |*sl| {
                    sl.src = resolve(sl.src, copyMap);
                },
                .array_literal => |*al| {
                    for (al.elements) |*elem| {
                        elem.* = resolve(elem.*, copyMap);
                    }
                },
                .list_literal => |*ll| {
                    for (ll.elements) |*elem| {
                        elem.* = resolve(elem.*, copyMap);
                    }
                },
                .array_load => |*al| {
                    al.array.operand = resolve(al.array.operand, copyMap);
                    al.index = resolve(al.index, copyMap);
                },
                .list_load => |*ll| {
                    ll.list.operand = resolve(ll.list.operand, copyMap);
                    ll.index = resolve(ll.index, copyMap);
                },
                .array_store => |*as| {
                    as.array.operand = resolve(as.array.operand, copyMap);
                    as.index = resolve(as.index, copyMap);
                    as.src = resolve(as.src, copyMap);
                },
                .list_store => |*ls| {
                    ls.list.operand = resolve(ls.list.operand, copyMap);
                    ls.index = resolve(ls.index, copyMap);
                    ls.src = resolve(ls.src, copyMap);
                },
                else => {},
            }
        },
        .print => |*pi| {
            pi.src = resolve(pi.src, copyMap);
        },
        else => {},
    }
}

// this does not protect against cycles
fn resolve(op: Operand, copyMap: *HashMap(Operand, Operand)) Operand {
    var cur = op;
    while (copyMap.get(cur)) |next| {
        cur = next;
    }
    return cur;
}

test "basic block copy prop" {
    const alloc = std.testing.allocator;

    var program = try Program.init(alloc);
    defer program.deinit(alloc);
    var instructions = &program.main.blocks.items[0].instructions;

    // t1 = t0
    try instructions.append(alloc, Instruction{ .move = .{
        .dst = .{ .temp = .{ .id = 1, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
    } });
    // t2 = t1
    try instructions.append(alloc, Instruction{ .move = .{
        .dst = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 1, .function_id = 0 } },
    } });
    // print(t2)
    try instructions.append(alloc, Instruction{ .print = .{
        .src = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .type = .int,
    } });

    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);

    // t1 = t0
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .move = .{
        .dst = .{ .temp = .{ .id = 1, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
    } });
    // t2 = t0
    try std.testing.expectEqualDeep(new_instructions[1], Instruction{ .move = .{
        .dst = .{ .temp = .{ .id = 2, .function_id = 0 } },
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
    } });
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[2], Instruction{ .print = .{
        .src = .{ .temp = .{ .id = 0, .function_id = 0 } },
        .type = .int,
    } });
}
