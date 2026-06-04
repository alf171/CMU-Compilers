const common = @import("common");
const color = @import("middle").color;

pub const first_param_reg = "x0";
pub const callee_return_reg = "x0";
pub const scratch_reg = "x1";

/// callee safe registers
pub const callee_safe_regs = [_][]const u8{ "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28" };

pub fn regFor(op: common.alloc.Operand, colors: *const color.ColoredGraph) ![]const u8 {
    switch (op) {
        .temp => {
            const node = colors.nodes.get(op) orelse return error.MissingColor;
            const reg_id = node.register orelse return error.MissingColor;

            if (reg_id >= callee_safe_regs.len) return error.RegisterOutOfRange;
            return callee_safe_regs[reg_id];
        },
        else => return error.UnsupportedOperand,
    }
}

pub fn paramRegFor(index: usize) ![]const u8 {
    return switch (index) {
        0 => "x0",
        1 => "x1",
        2 => "x2",
        3 => "x3",
        4 => "x4",
        5 => "x5",
        6 => "x6",
        7 => "x7",
        else => error.TooManyArgs,
    };
}
