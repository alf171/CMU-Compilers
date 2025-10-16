const std = @import("std");
const parser = @import("parse.zig");
const live = @import("live.zig");

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
pub fn spillReg(current_program: *const parser.Program, reg: parser.Operand, allocator: std.mem.Allocator) !parser.Program {
    // create a new program to not intefer with current looping
    var new_program = parser.Program{ .lines = std.array_list.Managed(parser.Line).init(allocator), .register_count = current_program.register_count, .max_temp_reg = current_program.max_temp_reg, .mem_pointer = current_program.mem_pointer };

    const memory_pointer = new_program.mem_pointer;
    new_program.mem_pointer += 1;
    outer: for (current_program.lines.items) |line| {
        // case 1: spill reg == the register defined in the line
        // introduce another temp to reduce complexity of reusing spill_reg
        // let coalescing handle copies
        if (line.defines.ops.items.len > 0 and parser.Operand.equal(line.defines.ops.items[0], reg)) {
            // p1: temp_new <- expr
            var temp = parser.Operands.init(allocator);
            try temp.ops.append(parser.Operand{ .temp = new_program.max_temp_reg });
            const temp_line_number: i32 = @intCast(new_program.lines.items.len + 1);
            const p1 = parser.Line{ .uses = try line.uses.clone(allocator), .live_out = parser.Operands.init(allocator), .defines = temp, .line_number = temp_line_number, .move = line.move };
            try new_program.lines.append(p1);
            // p2: M[] <- temp_new
            var mem = parser.Operands.init(allocator);
            try mem.ops.append(parser.Operand{ .mem = memory_pointer });
            const new_uses = try temp.clone(allocator);
            const new_line_number: i32 = @intCast(new_program.lines.items.len + 1);
            const new_line = parser.Line{ .uses = new_uses, .live_out = parser.Operands.init(allocator), .defines = mem, .line_number = new_line_number, .move = false };
            try new_program.lines.append(new_line);
            new_program.max_temp_reg += 1;
            continue :outer;
        }
        // case 2: spill reg is in use list
        for (line.uses.ops.items) |op| {
            if (op.equal(reg)) {
                // p1: temp_i <- load mem_j
                var temp = parser.Operands.init(allocator);
                try temp.ops.append(parser.Operand{ .temp = new_program.max_temp_reg });
                var mem = parser.Operands.init(allocator);
                try mem.ops.append(parser.Operand{ .mem = memory_pointer });
                const new_line_number: i32 = @intCast(new_program.lines.items.len + 1);
                const new_line = parser.Line{ .live_out = parser.Operands.init(allocator), .defines = temp, .line_number = new_line_number, .move = line.move, .uses = mem };
                try new_program.lines.append(new_line);
                // p2: replace reg_{spill} with temp_i
                var mut_uses = try parser.Operands.remove(line.uses, reg, allocator);
                try mut_uses.ops.append(parser.Operand{ .temp = new_program.max_temp_reg });
                const mut_defines = try line.defines.clone(allocator);
                const mut_line_count: i32 = @intCast(new_program.lines.items.len + 1);
                const rewritten_line = parser.Line{ .uses = mut_uses, .defines = mut_defines, .live_out = parser.Operands.init(allocator), .move = line.move, .line_number = mut_line_count };
                try new_program.lines.append(rewritten_line);

                new_program.max_temp_reg += 1;
                continue :outer;
            }
        }
        // case 3: spill reg is in the live_out only
        if (line.live_out.contains(reg)) {
            const new_line_number: i32 = @intCast(new_program.lines.items.len + 1);
            const new_line = parser.Line{ .live_out = parser.Operands.init(allocator), .defines = try line.defines.clone(allocator), .line_number = new_line_number, .move = line.move, .uses = try line.uses.clone(allocator) };
            try new_program.lines.append(new_line);
            continue :outer;
        }

        // default: just copy untouched line
        // line number needs to be recalculated at least!
        const new_line_number: i32 = @intCast(new_program.lines.items.len + 1);
        const new_line = parser.Line{ .uses = try line.uses.clone(allocator), .defines = try line.defines.clone(allocator), .live_out = parser.Operands.init(allocator), .move = line.move, .line_number = new_line_number };
        try new_program.lines.append(new_line);
    }
    // std.log.debug("", .{ spill_info.def, spill_info.uses });
    return new_program;
}

test "spillReg basic spill of defined reg" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const reg = parser.Operand{ .temp = 1 };

    var defines_ops = parser.Operands.init(allocator);
    try defines_ops.ops.append(reg);

    const uses_ops = parser.Operands.init(allocator);
    const live_out_ops = parser.Operands.init(allocator);

    const line = parser.Line{
        .defines = defines_ops,
        .uses = uses_ops,
        .live_out = live_out_ops,
        .line_number = 0,
        .move = false,
    };

    var lines = std.array_list.Managed(parser.Line).init(allocator);
    try lines.append(line);

    const program = parser.Program{
        .lines = lines,
        .register_count = 2,
        .max_temp_reg = 4,
        .mem_pointer = 10,
    };

    const new_prog = try spillReg(program, reg, allocator);
    defer {
        new_prog.deinit();
    }

    try std.testing.expect(new_prog.mem_pointer == program.mem_pointer + 1);
    try std.testing.expect(new_prog.lines.items.len > 0);
}
