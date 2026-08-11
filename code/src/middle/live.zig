const std = @import("std");
const expect = std.testing.expect;
const parser = @import("parse.zig");

const common = @import("common");
const WorkList = @import("common").alloc.WorkList;
const AllocBlock = common.alloc.AllocBlock;
const BlockId = common.ir.BlockId;
const Line = common.alloc.AllocLine;
const RegisterOperands = common.alloc.RegisterOperands;
const Operand = common.alloc.Operand;

/// handle case where we are last line in addition to other to rest
pub fn calculateLiveOut(program: *const common.alloc.AllocProgram, alloc: std.mem.Allocator) !void {
    var live_before: RegisterOperands = .init(alloc);
    defer live_before.free();

    var live_after: RegisterOperands = .init(alloc);
    defer live_after.free();

    var work_list: WorkList = try .init(program.blocks.items.len, alloc);
    defer work_list.deinit(alloc);

    const block_live_ins = try alloc.alloc(RegisterOperands, program.blocks.items.len);
    for (block_live_ins) |*block_live_in| {
        block_live_in.* = .init(alloc);
    }
    defer {
        for (block_live_ins) |*block_live_in| {
            block_live_in.free();
        }
        alloc.free(block_live_ins);
    }

    for (0..program.blocks.items.len) |i| {
        try work_list.enqueue(@intCast(i), alloc);
    }

    var iterations: usize = 0;

    while (work_list.pop()) |block_i| {
        iterations += 1;
        const block = program.blocks.items[block_i];

        live_before.ops.clearRetainingCapacity();
        live_after.ops.clearRetainingCapacity();

        // live_out[block] = union(successor LIVE_IN)
        for (block.successors.items) |successor_id| {
            const successor = program.blocks.items[successor_id];
            std.debug.assert(successor.function_id == block.function_id);

            try live_after.add(&block_live_ins[successor_id]);
        }
        // walk instructions in backwards order
        var index: usize = block.end;
        while (index > block.start) {
            index -= 1;
            var line = &program.lines.items[index];

            if (!line.live_out.equal(&live_after)) {
                line.live_out.ops.clearRetainingCapacity();
                try line.live_out.add(&live_after);
            }
            live_before.ops.clearRetainingCapacity();
            try getLiveIn(line, &live_before);
            std.mem.swap(RegisterOperands, &live_before, &live_after);
        }
        const cached_live_in = &block_live_ins[block_i];
        if (!cached_live_in.equal(&live_after)) {
            cached_live_in.ops.clearRetainingCapacity();
            try cached_live_in.add(&live_after);

            for (block.predecessors.items) |pred_id| {
                try work_list.enqueue(pred_id, alloc);
            }
        }
    }
}

/// Live_in(line) = Uses(line) u (Live_out(line) - Define(line))
/// NOTE: could be written more efficently
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

    var uses: RegisterOperands = .init(alloc);
    defer uses.free();
    try uses.ops.put(.{ .temp = .{ .id = 0, .function_id = 0 } }, .{ .type = .gp, .width = 1 });

    var defines: RegisterOperands = .init(alloc);
    defer defines.free();
    try defines.ops.put(.{ .temp = .{ .id = 1, .function_id = 0 } }, .{ .type = .gp, .width = 1 });

    var live_out: RegisterOperands = .init(alloc);
    defer live_out.free();
    const temps = [_]Operand{
        .{ .temp = .{ .id = 0, .function_id = 0 } },
        .{ .temp = .{ .id = 1, .function_id = 0 } },
        .{ .temp = .{ .id = 2, .function_id = 0 } },
    };
    for (temps) |temp| try live_out.ops.put(temp, .{ .type = .gp, .width = 1 });

    const line: Line = .{
        .uses = uses,
        .defines = defines,
        .live_out = live_out,
        .move = false,
        .clobber_caller_saved = false,
        .instruction_index = 1,
    };

    var result: RegisterOperands = .init(alloc);
    try getLiveIn(&line, &result);
    defer result.free();

    try std.testing.expectEqual(@as(usize, 2), result.ops.count());
    try std.testing.expect(result.ops.contains(.{ .temp = .{ .id = 0, .function_id = 0 } }));
    try std.testing.expect(result.ops.contains(.{ .temp = .{ .id = 2, .function_id = 0 } }));
}
