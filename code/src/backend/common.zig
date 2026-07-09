const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const color = @import("middle").color;

pub fn valueAsImm(value: ValueRef) ?i64 {
    return switch (value) {
        .constant => |c| switch (c) {
            .i64, .i32 => |i| @intCast(i),
            else => null,
        },
        .operand => null,
    };
}
