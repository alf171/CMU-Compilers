const std = @import("std");
const expect = std.testing.expect;
const parser = @import("parse.zig");

const common = @import("common");
const Line = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const Operand = common.alloc.Operand;

/// handle case where we are last line in addition to other to rest
pub fn calculateLiveOut(program: common.alloc.AllocProgram) !void {
    for (program.blocks.items) |*block| {
        var index: usize = block.end;
        while (index > block.start + 1) {
            index -= 1;
            const next_line = program.lines.items[index];
            try getLiveIn(&program.lines.items[index - 1].live_out, next_line);
        }
    }
}

/// Live_in(line) = Uses(line) u (Live_out(line) - Define(line))
/// memory semantics, we are going to return new memory while keeping prev valid
fn getLiveIn(result: *Operands, line: Line) !void {
    try result.add(&line.uses);
    var it = line.live_out.ops.keyIterator();
    while (it.next()) |live_out| {
        // dont add duplicates + dont add if in define
        if (!line.uses.ops.contains(live_out.*) and !line.defines.ops.contains(live_out.*)) {
            try result.ops.put(live_out.*, {});
        }
    }
}

test "out of bounds returns empty" {
    const alloc = std.testing.allocator;

    var line = Line{
        .uses = Operands.init(alloc),
        .defines = Operands.init(alloc),
        .live_out = Operands.init(alloc),
        .move = false,
        .instruction_index = 0,
    };
    defer line.deinit();

    var result = Operands.init(alloc);
    defer result.free();

    try getLiveIn(&result, line);

    try std.testing.expectEqual(@as(usize, 0), result.ops.count());
}

test "simple example" {
    const alloc = std.testing.allocator;

    var uses = Operands.init(alloc);
    defer uses.free();
    try uses.ops.put(Operand{ .temp = 0 }, {});

    var defines = Operands.init(alloc);
    defer defines.free();
    try defines.ops.put(Operand{ .temp = 1 }, {});

    var live_out = Operands.init(alloc);
    defer live_out.free();
    const temps = [_]Operand{
        .{ .temp = 0 },
        .{ .temp = 1 },
        .{ .temp = 2 },
    };
    for (temps) |temp| try live_out.ops.put(temp, {});

    const line = Line{
        .uses = uses,
        .defines = defines,
        .live_out = live_out,
        .move = false,
        .instruction_index = 1,
    };

    var result = Operands.init(alloc);
    defer result.free();
    try getLiveIn(&result, line);

    try std.testing.expectEqual(@as(usize, 2), result.ops.count());
    try std.testing.expect(result.ops.contains(Operand{ .temp = 0 }));
    try std.testing.expect(result.ops.contains(Operand{ .temp = 2 }));
}
