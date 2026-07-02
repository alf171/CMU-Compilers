const std = @import("std");
const Operand = @import("common").alloc.Operand;
const ValueRef = @import("common").ir.ValueRef;
const ColoredGraph = @import("middle").color.ColoredGraph;

pub const Abi = struct {
    function_arg_regs: []const []const u8,
    caller_save_regs: []const []const u8,
    callee_save_regs: []const []const u8,
    allocatable_regs: []const []const u8,
    /// calculation could be moved to comptime
    call_clobber_mask: u32,
    /// the index in allocatable_regs which the function_return reg is held
    function_return_idx: u8,

    pub fn init(
        function_arg_regs: []const []const u8,
        caller_save_regs: []const []const u8,
        callee_save_regs: []const []const u8,
        function_return_idx: u8,
    ) @This() {
        // [ high bits ] [ low bits ]
        // [ callee safe bits ] [ caller safe bits ] [function param bits]
        const caller_save_mask: u32 = mask(caller_save_regs.len, function_arg_regs.len);
        const function_param_mask: u32 = mask(function_arg_regs.len, 0);

        return .{
            .function_arg_regs = function_arg_regs,
            .caller_save_regs = caller_save_regs,
            .callee_save_regs = callee_save_regs,
            .allocatable_regs = function_arg_regs ++ caller_save_regs ++ callee_save_regs,
            .call_clobber_mask = caller_save_mask | function_param_mask,
            .function_return_idx = function_return_idx,
        };
    }

    /// checks if index provided is in bounds
    pub fn getIndex(self: @This(), index: usize) !u8 {
        if (index >= self.function_arg_regs.len) return error.OutOfBounds;

        return @intCast(index);
    }

    /// convert an index into a register
    pub fn paramRegFor(self: @This(), index: usize) ![]const u8 {
        if (index >= self.function_arg_regs.len) return error.TooManyArgs;
        return self.function_arg_regs[index];
    }

    pub fn regForFromIndex(self: @This(), index: usize) ![]const u8 {
        if (index >= self.allocatable_regs.len) return error.TooManyArgs;
        return self.allocatable_regs[index];
    }

    pub fn regFor(self: @This(), op: Operand, colors: *const ColoredGraph) ![]const u8 {
        switch (op) {
            .temp => {
                const node = colors.nodes.get(op) orelse {
                    std.debug.print("Missing color for operand: ", .{});
                    op.print();
                    std.debug.print("\n", .{});
                    return error.MissingColor;
                };
                const reg_id = node.register orelse return error.MissingColor;

                if (reg_id >= self.allocatable_regs.len) return error.RegisterOutOfRange;
                return self.allocatable_regs[reg_id];
            },
            else => return error.UnsupportedOperand,
        }
    }
};

fn mask(comptime width: usize, comptime shift: usize) u32 {
    return @intCast(((1 << width) - 1) << shift);
}
