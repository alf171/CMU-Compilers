const std = @import("std");
const ArrayList = std.array_list.Managed;

const BlockId = @import("common").ir.BlockId;
const BasicBlock = @import("common").ir.BasicBlock;
const Program = @import("common").ir.Program;
const Operand = @import("common").alloc.Operand;
const Instruction = @import("common").ir.Instruction;

const HashMap = std.AutoHashMap;

pub fn run(program: *Program, alloc: std.mem.Allocator) !void {
    for (program.main.blocks.items) |block| {
        // copy prop will only work within a basic block
        var copyMap = HashMap(Operand, Operand).init(alloc);
        defer copyMap.deinit();

        for (block.instructions.items) |*instruction| {
            rewriteUses(instruction, &copyMap);

            if (instruction.* == .move) {
                const dst = instruction.move.dst;
                const src = resolve(instruction.move.src, &copyMap);

                if (!dst.equal(src)) {
                    try copyMap.put(dst, src);
                }
            }
        }
    }
}

fn rewriteUses(instruction: *Instruction, copyMap: *HashMap(Operand, Operand)) void {
    switch (instruction.*) {
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
        .print => |*pi| {
            pi.src = resolve(pi.src, copyMap);
        },
        .array_literal => |*al| {
            for (al.elements) |*elem| {
                elem.* = resolve(elem.*, copyMap);
            }
        },
        .array_load => |*al| {
            al.array = resolve(al.array, copyMap);
            al.index = resolve(al.index, copyMap);
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
    try instructions.append(Instruction{ .move = .{
        .dst = .{ .temp = 1 },
        .src = .{ .temp = 0 },
    } });
    // t2 = t1
    try instructions.append(Instruction{ .move = .{
        .dst = .{ .temp = 2 },
        .src = .{ .temp = 1 },
    } });
    // print(t2)
    try instructions.append(Instruction{ .print = .{
        .src = .{ .temp = 2 },
        .type = .int,
    } });

    try run(&program, alloc);
    const new_instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(3, new_instructions.len);

    // t1 = t0
    try std.testing.expectEqualDeep(new_instructions[0], Instruction{ .move = .{
        .dst = .{ .temp = 1 },
        .src = .{ .temp = 0 },
    } });
    // t2 = t0
    try std.testing.expectEqualDeep(new_instructions[1], Instruction{ .move = .{
        .dst = .{ .temp = 2 },
        .src = .{ .temp = 0 },
    } });
    // print(t0)
    try std.testing.expectEqualDeep(new_instructions[2], Instruction{ .print = .{
        .src = .{ .temp = 0 },
        .type = .int,
    } });
}
