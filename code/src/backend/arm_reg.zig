const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const regFor = @import("common.zig").regFor;
const color = @import("middle").color;

pub const first_param_reg = "x0";
pub const callee_return_reg = "x0";
pub const scratch_reg = "x1";
pub const scratch_reg_2 = "x2";

/// callee safe registers
pub const callee_safe_regs = [_][]const u8{ "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28" };

/// caller safe registers
/// in order to allow using x0-x7, we need to write percoloring code so that we dont have a collision
pub const caller_safe_regs = [_][]const u8{ "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17" };

// [callee safe bits] [caller safe bits]
pub const register_mask: u32 = ((1 << caller_safe_regs.len) - 1) << callee_safe_regs.len;

pub const allocatable_regs = callee_safe_regs ++ caller_safe_regs;

pub fn valueToReg(
    value: ValueRef,
    out: *std.ArrayList(u8),
    cur_scratch_reg: []const u8,
    colors: *const color.ColoredGraph,
    alloc: std.mem.Allocator,
) ![]const u8 {
    switch (value) {
        .operand => |op| return regFor(op.operand, colors, &allocatable_regs),
        .constant => |c| {
            switch (c) {
                .i32, .i64 => |i| {
                    try out.print(alloc, "mov {s}, #{d}\n", .{ cur_scratch_reg, i });
                    return cur_scratch_reg;
                },
                else => return error.NotImpl,
            }
        },
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

pub fn condForCmp(op: common.ir.CmpOp) []const u8 {
    return switch (op) {
        .eq => "eq",
        .neq => "ne",
        .lt => "lt",
        .lte => "le",
        .gt => "gt",
        .gte => "ge",
    };
}
