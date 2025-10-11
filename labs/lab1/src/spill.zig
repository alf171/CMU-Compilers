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
pub fn spillReg(current_program: parser.Program, reg: parser.Operand, allocator: std.mem.Allocator) !parser.Program {
    // create a new program to not intefer with current looping
    const new_program = parser.Program{ .lines = parser.Operands.init(allocator), .register_count = current_program.register_count, .max_temp_reg = current_program.max_temp_reg, .mem_pointer = current_program.mem_pointer + 1 };
    for (current_program.lines) |line| {
        // case 1: spill reg == the register defined in the line
        if (line.defines.ops.len > 0 and parser.Operand.equal(line.defines.ops[0], reg)) {
            std.debug.assert(line.defines.ops[0] != null);
            try new_program.lines.append(line);
            const new_uses = parser.Operands{ .ops = line.defines.ops.clone() };
            const new_live_out = parser.Operands{ .ops = line.live_out.ops.clone() };
            const new_defines = parser.Operands.init(allocator);
            const new_line_number = new_program.lines.len - 1;
            const new_line = parser.Line{ .uses = new_uses, .live_out = new_live_out, .defines = new_defines, .line_number = new_line_number, .move = false };
            try new_program.lines.append(new_line);
            continue;
        }
        // case 2: spill reg is in use list
        for (line.uses.ops) |op| {
            if (op.equal(reg)) {
                const new_operands = parser.Operands{ .ops = parser.Operand{ .mem = current_program.mem_pointer - 1 } };
                const new_line_live_out = live.getLiveOut(current_program.lines, new_program.lines.len, allocator);
                const new_line = parser.Line{ .live_out = new_line_live_out, .defines = new_operands, .line_number = new_program.lines.len, .move = line.move, .uses = parser.Operands{ .ops = line.defines.ops.clone() } };
                try new_program.lines.append(new_line);
                // mutate current line to consume new temp reg
                const mut_uses = try parser.Operands.remove(line.uses, reg);
                mut_uses.ops.append(parser.Operand{ .mem = current_program.mem_pointer - 1 });
                const mut_defines = parser.Operands{ .ops = line.defines.ops.clone() };
                const mut_live_out = parser.Operands{ .ops = line.live_out.ops.clone() };
                const mut_line_count = new_program.lines.len - 2;
                const rewritten_line = parser.Line{ .uses = mut_uses, .defines = mut_defines, .live_out = mut_live_out, .move = line.move, .line_number = mut_line_count };
                try new_program.lines.append(rewritten_line);
                continue;
            }
        }
        // case 3: spill reg is in the live_out only
        if (line.live_out.contains(reg)) {
            const new_live_out = parser.Operands.remove(line.live_out, reg);
            const new_defines = parser.Operands{ .ops = line.defines.ops.clone() };
            const new_uses = parser.Operands{ .ops = line.defines.uses.clone() };
            const new_line = parser.Line{ .live_out = new_live_out, .defines = new_defines, .line_number = new_program.lines.len - 1, .move = line.move, .uses = new_uses };
            try new_program.lines.append(new_line);
            continue;
        }
    }
    // std.log.debug("", .{ spill_info.def, spill_info.uses });
    return new_program;
}
