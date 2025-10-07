const std = @import("std");
const parser = @import("parse.zig");

const SpillInfo = struct {
    def: parser.Line,
    uses: std.array_list(parser.Line),

    fn init(allocator: std.mem.Allocator) SpillInfo {
        std.array_list.Managed(parser.Line).init(allocator);
    }

    /// spill info borrows memory so just free the array shell
    fn deinit(self: SpillInfo) void {
        self.deinit();
    }
};

/// build a new program which spill the register provided
/// general alg:
/// 1. after def, load register into spill or memory
///   - wait this is really two uses??
///   - M[] <- w (new_line)
///   - w' <- M[] (another new line)
///   - x <- w' + v (modified current line)
/// 2. before each use of register, load new temp from value in memory
///   - replace use of register with newly created temp
///   - w'' <- M[] (new_line)
///   - _ <- w'' + x (modified current line)
pub fn spillReg(current_program: parser.Program, reg: parser.Operand, allocator: std.mem.Allocator) !parser.Program {
    const spill_info = SpillInfo.init(allocator);
    // create a new program to not intefer with current looping
    const new_program = parser.Program{ .lines = {}, .register_count = current_program.register_count, .max_temp_reg = current_program.max_temp_reg };
    var new_lines = std.array_list.Managed(parser.Line).init(allocator);
    defer new_lines.deinit();
    for (current_program.lines) |line| {
        // case 1
        if (line.defines.ops.len > 0 and parser.Operand.equal(line.defines.ops[0], reg)) {
            std.debug.assert(line.defines.ops[0] != null);
            spill_info.def = line.defines.ops[0];
            continue;
        }
        // case 2
        for (line.uses.ops) |op| {
            if (op.equal(reg)) {
                spill_info.uses.append(line);
            }
        }
        try new_lines.append(line);
    }
    new_program.lines = try new_lines.toOwnedSlice();
    std.log.debug("def: {any}, uses: {any}", .{ spill_info.def, spill_info.uses });
    return new_program;
}
