const std = @import("std");
const expect = std.testing.expect;
const parser = @import("parse.zig");

const common = @import("common");
const AllocBlock = common.alloc.AllocBlock;
const Line = common.alloc.AllocLine;
const RegisterOperands = common.alloc.RegisterOperands;
const Operand = common.alloc.Operand;

/// handle case where we are last line in addition to other to rest
pub fn calculateLiveOut(program: *const common.alloc.AllocProgram, alloc: std.mem.Allocator) !void {
    var iterations: usize = 0;
    var live_before = RegisterOperands.init(alloc);
    defer live_before.free();

    var live_after = RegisterOperands.init(alloc);
    defer live_after.free();

    var changed = true;
    // TODO: use bitmask 0 = maybe be added to the queue, 1 = block is already in the queue
    // a worklist algorithm will need to keep track of predecessors also!
    // today, we are fine since we just walk everything
    while (changed) {
        iterations += 1;
        changed = false;
        var changed_lines: usize = 0;
        var block_i = program.blocks.items.len;
        while (block_i > 0) {
            block_i -= 1;
            const block = program.blocks.items[block_i];

            live_before.ops.clearRetainingCapacity();
            live_after.ops.clearRetainingCapacity();

            for (block.successors.items) |id| {
                std.debug.assert(id < program.blocks.items.len);
                const succ_block = program.blocks.items[id];
                std.debug.assert(succ_block.function_id == block.function_id);

                if (succ_block.start == succ_block.end) continue;
                std.debug.assert(succ_block.start < succ_block.end);

                live_before.ops.clearRetainingCapacity();
                try getLiveIn(&program.lines.items[succ_block.start], &live_before);
                try live_after.add(&live_before);
            }

            var index: usize = block.end;
            while (index > block.start) {
                index -= 1;
                var line = &program.lines.items[index];
                if (!line.live_out.equal(&live_after)) {
                    line.live_out.ops.clearRetainingCapacity();
                    try line.live_out.add(&live_after);
                    changed = true;
                    changed_lines += 1;
                }
                live_before.ops.clearRetainingCapacity();
                try getLiveIn(line, &live_before);
                std.mem.swap(RegisterOperands, &live_before, &live_after);
            }
        }
        std.debug.print("liveness {d} iterations, {d} changed lines, {d} lines\n", .{
            iterations,
            changed_lines,
            program.lines.items.len,
        });
    }
}

/// Live_in(line) = Uses(line) u (Live_out(line) - Define(line))
/// memory semantics, we are going to return new memory while keeping prev valid
fn getLiveIn(
    line: *const Line,
    result: *RegisterOperands,
) !void {
    try result.add(&line.uses);

    var it = line.live_out.ops.iterator();
    while (it.next()) |entry| {
        const live_out = entry.key_ptr.*;
        // dont add duplicates + dont add if in define
        if (!line.uses.ops.contains(live_out) and !line.defines.ops.contains(live_out)) {
            try result.ops.put(live_out, entry.value_ptr.*);
        }
    }
}

test "out of bounds returns empty" {
    const alloc = std.testing.allocator;

    var line: Line = .{
        .uses = RegisterOperands.init(alloc),
        .defines = RegisterOperands.init(alloc),
        .live_out = RegisterOperands.init(alloc),
        .move = false,
        .clobber_caller_saved = false,
        .instruction_index = 0,
    };
    defer line.deinit();

    var result = RegisterOperands.init(alloc);
    try getLiveIn(&line, &result);
    defer result.free();

    try std.testing.expectEqual(@as(usize, 0), result.ops.count());
}

test "simple example" {
    const alloc = std.testing.allocator;

    var uses = RegisterOperands.init(alloc);
    defer uses.free();
    try uses.ops.put(.{ .temp = .{ .id = 0, .function_id = 0 } }, .gp);

    var defines = RegisterOperands.init(alloc);
    defer defines.free();
    try defines.ops.put(.{ .temp = .{ .id = 1, .function_id = 0 } }, .gp);

    var live_out = RegisterOperands.init(alloc);
    defer live_out.free();
    const temps = [_]Operand{
        .{ .temp = .{ .id = 0, .function_id = 0 } },
        .{ .temp = .{ .id = 1, .function_id = 0 } },
        .{ .temp = .{ .id = 2, .function_id = 0 } },
    };
    for (temps) |temp| try live_out.ops.put(temp, .gp);

    const line: Line = .{
        .uses = uses,
        .defines = defines,
        .live_out = live_out,
        .move = false,
        .clobber_caller_saved = false,
        .instruction_index = 1,
    };

    var result = RegisterOperands.init(alloc);
    try getLiveIn(&line, &result);
    defer result.free();

    try std.testing.expectEqual(@as(usize, 2), result.ops.count());
    try std.testing.expect(result.ops.contains(Operand{ .temp = .{ .id = 0, .function_id = 0 } }));
    try std.testing.expect(result.ops.contains(Operand{ .temp = .{ .id = 2, .function_id = 0 } }));
}
