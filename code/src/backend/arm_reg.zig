const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const regFor = @import("common.zig").regFor;
const color = @import("middle").color;

pub const first_param_reg = "x0";
pub const callee_return_reg = "x0";
// reserve two regs for scratch purposes
pub const scratch_reg = "x16";
pub const scratch_reg_2 = "x17";

/// function param registers
pub const function_param_regs = [_][]const u8{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7" };

/// callee save registers
pub const callee_save_regs = [_][]const u8{ "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28" };

/// caller save registers
/// in order to allow using x0-x7, we need to write percoloring code so that we dont have a collision
pub const caller_save_regs = [_][]const u8{ "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15" };

pub fn mask(comptime width: usize, comptime shift: usize) u32 {
    return @intCast(((1 << width) - 1) << shift);
}

// [ high bits ] [ low bits ]
// [ callee safe bits ] [ caller safe bits ] [function param bits]
const caller_save_mask: u32 = mask(caller_save_regs.len, function_param_regs.len);

const function_param_mask: u32 = mask(function_param_regs.len, 0);

pub const call_clobber_mask: u32 = caller_save_mask | function_param_mask;

pub const allocatable_regs = function_param_regs ++ caller_save_regs ++ callee_save_regs;

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
