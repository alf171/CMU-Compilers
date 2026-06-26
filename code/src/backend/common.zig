const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const color = @import("middle").color;

pub fn regFor(op: common.alloc.Operand, colors: *const color.ColoredGraph, regs: []const []const u8) ![]const u8 {
    switch (op) {
        .temp => {
            const node = colors.nodes.get(op) orelse {
                std.debug.print("Missing color for operand: ", .{});
                op.print();
                std.debug.print("\n", .{});
                return error.MissingColor;
            };
            const reg_id = node.register orelse return error.MissingColor;

            if (reg_id >= regs.len) return error.RegisterOutOfRange;
            return regs[reg_id];
        },
        // .reg => {},
        else => return error.UnsupportedOperand,
    }
}

pub const BackendValue = struct {
    register: []const u8,
    value: u8,
};

pub fn valueAsImm(value: ValueRef) ?i64 {
    return switch (value) {
        .constant => |c| switch (c) {
            .i64, .i32 => |i| @intCast(i),
            else => null,
        },
        .operand => null,
    };
}
