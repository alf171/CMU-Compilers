const std = @import("std");
const parser = @import("parse.zig");
const live = @import("live.zig");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const Program = common.alloc.AllocProgram;
const Block = common.alloc.AllocBlock;
const Line = common.alloc.AllocLine;
const Operands = common.alloc.Operands;
const Operand = common.alloc.Operand;

pub fn spillReg(current_program: *const Program, reg: Operand, alloc: std.mem.Allocator) !Program {
    var new_program = Program{
        .lines = ArrayList(Line).init(alloc),
        .blocks = ArrayList(Block).init(alloc),
        .register_count = current_program.register_count,
    };
    errdefer new_program.deinit();

    var next_temp = current_program.nextTemp();
    const memory_pointer = current_program.nextMem();

    for (current_program.blocks.items) |block| {
        const new_start = new_program.lines.items.len;
        for (current_program.lines.items[block.start..block.end]) |line| {
            try spillLine(&new_program, line, reg, memory_pointer, &next_temp, alloc);
        }

        var successors = ArrayList(u32).init(alloc);
        try successors.appendSlice(block.successors.items);

        try new_program.blocks.append(.{
            .id = block.id,
            .start = new_start,
            .end = new_program.lines.items.len,
            .successors = successors,
        });
    }

    // std.log.debug("", .{ spill_info.def, spill_info.uses });
    return new_program;
}

/// build a new program which spill the register provided
/// general alg:
/// 1. after def, load register into spill or memory
///   - w <- v + 3 (current line) (unchanged)
///   - M[] <- w (new line)
/// 2. before each use of register, load new temp from value in memory
///   - replace use of register with newly created temp
///   - w'' <- M[] (new_line)
///   - _ <- w'' + x (modified current line)
/// 3. edit live_out graph between steps (we could consider restoring live_out
fn spillLine(
    new_program: *Program,
    line: Line,
    reg: Operand,
    memory_pointer: u8,
    next_temp: *u8,
    alloc: std.mem.Allocator,
) !void {
    // case 1: spill reg == the register defined in the line
    // introduce another temp to reduce complexity of reusing spill_reg
    // let coalescing handle copies
    if (line.defines.ops.count() > 0 and Operand.equal(try line.defines.single(), reg)) {
        // p1: temp_new <- expr
        var temp = Operands.init(alloc);
        try temp.ops.put(Operand{ .temp = next_temp.* }, {});
        const temp_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const p1 = Line{ .uses = try line.uses.clone(alloc), .live_out = Operands.init(alloc), .defines = temp, .instruction_index = temp_line_number, .move = line.move };
        try new_program.lines.append(p1);
        // p2: M[] <- temp_new
        var mem = Operands.init(alloc);
        try mem.ops.put(Operand{ .mem = memory_pointer }, {});
        const new_uses = try temp.clone(alloc);
        const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const new_line = Line{ .uses = new_uses, .live_out = Operands.init(alloc), .defines = mem, .instruction_index = new_line_number, .move = false };
        try new_program.lines.append(new_line);
        next_temp.* += 1;
        return;
    }
    // case 2: spill reg is in use list
    var it = line.uses.ops.keyIterator();
    while (it.next()) |op| {
        if (op.*.equal(reg)) {
            // p1: temp_i <- load mem_j
            var temp = Operands.init(alloc);
            try temp.ops.put(Operand{ .temp = next_temp.* }, {});
            var mem = Operands.init(alloc);
            try mem.ops.put(Operand{ .mem = memory_pointer }, {});
            const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
            const new_line = Line{ .live_out = Operands.init(alloc), .defines = temp, .instruction_index = new_line_number, .move = line.move, .uses = mem };
            try new_program.lines.append(new_line);
            // p2: replace reg_{spill} with temp_i
            // std.debug.print("trying to remove {any} from line.uses: {any}", .{ reg, line.uses.ops.items });
            var mut_uses = try Operands.remove(line.uses, reg, alloc);
            try mut_uses.ops.put(Operand{ .temp = next_temp.* }, {});
            const mut_defines = try line.defines.clone(alloc);
            const mut_line_count: usize = @intCast(new_program.lines.items.len + 1);
            const rewritten_line = Line{ .uses = mut_uses, .defines = mut_defines, .live_out = Operands.init(alloc), .move = line.move, .instruction_index = mut_line_count };
            try new_program.lines.append(rewritten_line);

            next_temp.* += 1;
            return;
        }
    }
    // case 3: spill reg is in the live_out only
    if (line.live_out.ops.contains(reg)) {
        const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
        const new_line = Line{ .live_out = Operands.init(alloc), .defines = try line.defines.clone(alloc), .instruction_index = new_line_number, .move = line.move, .uses = try line.uses.clone(alloc) };
        try new_program.lines.append(new_line);
        return;
    }

    // default: just copy untouched line
    // line number needs to be recalculated at least!
    const new_line_number: usize = @intCast(new_program.lines.items.len + 1);
    const new_line = Line{ .uses = try line.uses.clone(alloc), .defines = try line.defines.clone(alloc), .live_out = Operands.init(alloc), .move = line.move, .instruction_index = new_line_number };
    try new_program.lines.append(new_line);
}

test "spillReg basic spill of defined reg" {
    const allocator = std.testing.allocator;

    const reg = Operand{ .temp = 1 };

    var defines_ops = Operands.init(allocator);
    try defines_ops.ops.put(reg, {});

    const uses_ops = Operands.init(allocator);
    const live_out_ops = Operands.init(allocator);

    const line = Line{
        .defines = defines_ops,
        .uses = uses_ops,
        .live_out = live_out_ops,
        .instruction_index = 0,
        .move = false,
    };

    var lines = std.array_list.Managed(Line).init(allocator);
    try lines.append(line);

    var blocks = std.array_list.Managed(Block).init(allocator);
    try blocks.append(Block{ .id = 0, .start = 0, .end = lines.items.len, .successors = ArrayList(u32).init(allocator) });

    var program = Program{
        .lines = lines,
        .register_count = 2,
        .blocks = blocks,
    };
    defer program.deinit();

    var new_prog = try spillReg(&program, reg, allocator);
    defer new_prog.deinit();

    try std.testing.expect(new_prog.nextMem() == program.nextMem() + 1);
    try std.testing.expect(new_prog.lines.items.len > 0);
}
