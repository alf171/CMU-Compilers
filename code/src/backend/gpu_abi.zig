const std = @import("std");
const Operand = @import("common").alloc.Operand;
const ValueRef = @import("common").ir.ValueRef;
const ColoredGraph = @import("middle").color.ColoredGraph;
const TypeInfo = @import("common").types.TypeInfo;
const RegisterType = @import("common").ir.RegisterType;

pub const GpuAbi = struct {
    sgpr_allocatable_regs: []const []const u8,
    vgpr_allocatable_regs: []const []const u8,

    pub fn init(
        sgpr_allocatable_regs: []const []const u8,
        vgpr_allocatable_regs: []const []const u8,
    ) @This() {
        // [ high bits ] [ low bits ]
        // [ callee safe bits ] [ caller safe bits ] [function param bits]

        return .{
            .sgpr_allocatable_regs = sgpr_allocatable_regs,
            .vgpr_allocatable_regs = vgpr_allocatable_regs,
        };
    }

    fn regForFromIndex(self: @This(), index: usize, reg_type: RegisterType) ![]const u8 {
        const allocatable_regs = switch (reg_type) {
            .f => self.fp_allocatable_regs,
            .gp => self.gp_allocatable_regs,
        };
        if (index >= allocatable_regs.len) return error.TooManyArgs;
        return allocatable_regs[index];
    }

    pub fn regFor(self: @This(), op: Operand, colors: *const ColoredGraph, reg_type: RegisterType) ![]const u8 {
        switch (op) {
            .temp => {
                const node = colors.nodes.get(op) orelse {
                    std.debug.print("Missing color for operand: ", .{});
                    op.print();
                    std.debug.print("\n", .{});
                    return error.MissingColor;
                };
                const reg_id = node.register orelse return error.MissingColor;
                return try regForFromIndex(self, reg_id, reg_type);
            },
            .reg => |reg| {
                return try regForFromIndex(self, reg.id, reg.class);
            },
            else => return error.UnsupportedOperand,
        }
    }
};

fn mask(comptime width: usize, comptime shift: usize) u32 {
    return @intCast(((1 << width) - 1) << shift);
}
