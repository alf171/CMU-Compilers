const common = @import("common");
const color = @import("middle").color;

const arm_regs = [_][]const u8{
    "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16",
};

pub fn regFor(op: common.alloc.Operand, colors: *const color.ColoredGraph) ![]const u8 {
    switch (op) {
        .temp => {
            const node = colors.nodes.get(op) orelse return error.MissingColor;
            const reg_id = node.register orelse return error.MissingColor;

            if (reg_id >= arm_regs.len) return error.RegisterOutOfRange;
            return arm_regs[reg_id];
        },
        else => return error.UnsupportedOperand,
    }
}
