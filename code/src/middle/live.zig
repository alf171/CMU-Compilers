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
    var changed = true;
    while (changed) {
        changed = false;
        var block_i = program.blocks.items.len;
        while (block_i > 0) {
            block_i -= 1;
            const block = program.blocks.items[block_i];

            var live_after = RegisterOperands.init(alloc);
            defer live_after.free();

            for (block.successors.items) |id| {
                const succ_block = try program.getBlockById(id, block.function_id);

                if (succ_block.start == succ_block.end) continue;
                std.debug.assert(succ_block.start < succ_block.end);

                var succ_live_in = try getLiveIn(&program.lines.items[succ_block.start], alloc);
                defer succ_live_in.free();

                try live_after.add(&succ_live_in);
            }

            var index: usize = block.end;
            while (index > block.start) {
                index -= 1;
                var line = &program.lines.items[index];
                if (!line.live_out.equal(&live_after)) {
                    line.live_out.free();
                    line.live_out = try live_after.clone(alloc);
                    changed = true;
                }
                const live_in = try getLiveIn(line, alloc);
                live_after.free();
                live_after = live_in;
            }
        }
    }
}

/// Live_in(line) = Uses(line) u (Live_out(line) - Define(line))
/// memory semantics, we are going to return new memory while keeping prev valid
fn getLiveIn(line: *const Line, alloc: std.mem.Allocator) !RegisterOperands {
    var result = RegisterOperands.init(alloc);
    try result.add(&line.uses);

    var it = line.live_out.ops.iterator();
    while (it.next()) |entry| {
        const live_out = entry.key_ptr.*;
        // dont add duplicates + dont add if in define
        if (!line.uses.ops.contains(live_out) and !line.defines.ops.contains(live_out)) {
            try result.ops.put(live_out, entry.value_ptr.*);
        }
    }
    return result;
}

test "out of bounds returns empty" {
    const alloc = std.testing.allocator;

    var line = Line{
        .uses = RegisterOperands.init(alloc),
        .defines = RegisterOperands.init(alloc),
        .live_out = RegisterOperands.init(alloc),
        .move = false,
        .clobber_caller_saved = false,
        .instruction_index = 0,
    };
    defer line.deinit();

    var result = try getLiveIn(&line, alloc);
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

    const line = Line{
        .uses = uses,
        .defines = defines,
        .live_out = live_out,
        .move = false,
        .clobber_caller_saved = false,
        .instruction_index = 1,
    };

    var result = try getLiveIn(&line, alloc);
    defer result.free();

    try std.testing.expectEqual(@as(usize, 2), result.ops.count());
    try std.testing.expect(result.ops.contains(Operand{ .temp = .{ .id = 0, .function_id = 0 } }));
    try std.testing.expect(result.ops.contains(Operand{ .temp = .{ .id = 2, .function_id = 0 } }));
}
