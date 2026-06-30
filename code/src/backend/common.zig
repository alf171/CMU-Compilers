const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const color = @import("middle").color;

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
