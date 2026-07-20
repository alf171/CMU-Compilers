const std = @import("std");
const Operand = @import("common").alloc.Operand;
const ValueRef = @import("common").ir.ValueRef;
const ColoredGraph = @import("middle").color.ColoredGraph;
const TypeInfo = @import("common").types.TypeInfo;
const RegisterType = @import("common").ir.RegisterType;

// function_return_idx = idnex of in mask of the function return register
// mask calculation could be moved to comptime
pub const CpuAbi = struct {
    gp_function_arg_regs: []const []const u8,
    gp_caller_save_regs: []const []const u8,
    gp_callee_save_regs: []const []const u8,
    gp_allocatable_regs: []const []const u8,
    gp_call_clobber_mask: u32,
    gp_function_return_idx: u8,
    gp_scratch_regs: []const []const u8,
    fp_function_arg_regs: []const []const u8,
    fp_caller_save_regs: []const []const u8,
    fp_callee_save_regs: []const []const u8,
    fp_allocatable_regs: []const []const u8,
    fp_call_clobber_mask: u32,
    fp_function_return_idx: u8,
    fp_scratch_regs: []const []const u8,

    pub fn init(
        gp_function_arg_regs: []const []const u8,
        gp_caller_save_regs: []const []const u8,
        gp_callee_save_regs: []const []const u8,
        gp_function_return_idx: u8,
        gp_scratch_regs: []const []const u8,
        fp_function_arg_regs: []const []const u8,
        fp_caller_save_regs: []const []const u8,
        fp_callee_save_regs: []const []const u8,
        fp_function_return_idx: u8,
        fp_scratch_regs: []const []const u8,
    ) @This() {
        // [ high bits ] [ low bits ]
        // [ callee safe bits ] [ caller safe bits ] [function param bits]
        const gp_caller_save_mask: u32 = mask(gp_caller_save_regs.len, gp_function_arg_regs.len);
        const gp_function_param_mask: u32 = mask(gp_function_arg_regs.len, 0);
        const fp_caller_save_mask: u32 = mask(fp_caller_save_regs.len, fp_function_arg_regs.len);
        const fp_function_param_mask: u32 = mask(fp_function_arg_regs.len, 0);

        return .{
            .gp_function_arg_regs = gp_function_arg_regs,
            .gp_caller_save_regs = gp_caller_save_regs,
            .gp_callee_save_regs = gp_callee_save_regs,
            .gp_allocatable_regs = gp_function_arg_regs ++ gp_caller_save_regs ++ gp_callee_save_regs,
            .gp_call_clobber_mask = gp_caller_save_mask | gp_function_param_mask,
            .gp_function_return_idx = gp_function_return_idx,
            .gp_scratch_regs = gp_scratch_regs,
            .fp_function_arg_regs = fp_function_arg_regs,
            .fp_caller_save_regs = fp_caller_save_regs,
            .fp_callee_save_regs = fp_callee_save_regs,
            .fp_allocatable_regs = fp_function_arg_regs ++ fp_caller_save_regs ++ fp_callee_save_regs,
            .fp_call_clobber_mask = fp_caller_save_mask | fp_function_param_mask,
            .fp_function_return_idx = fp_function_return_idx,
            .fp_scratch_regs = fp_scratch_regs,
        };
    }

    pub fn getIndexForType(self: @This(), index: usize, type_info: TypeInfo) !u8 {
        return switch (type_info) {
            .float => try self.getIndex(index, .f),
            else => try self.getIndex(index, .gp),
        };
    }

    pub fn getFunctionReturnIdx(self: @This(), type_info: TypeInfo) u8 {
        return switch (type_info) {
            .float => self.fp_function_return_idx,
            else => self.gp_function_return_idx,
        };
    }

    /// checks if index provided is in bounds
    pub fn getIndex(self: @This(), index: usize, reg_type: RegisterType) !u8 {
        const function_arg_regs_len = switch (reg_type) {
            .f => self.fp_function_arg_regs.len,
            .gp => self.gp_function_arg_regs.len,
            else => unreachable,
        };

        if (index >= function_arg_regs_len) return error.OutOfBounds;
        return @intCast(index);
    }

    /// convert an index into a register
    pub fn paramRegFor(self: @This(), index: usize, reg_type: RegisterType) ![]const u8 {
        const function_arg_regs = switch (reg_type) {
            .f => self.fp_function_arg_regs,
            .gp => self.gp_function_arg_regs,
            else => unreachable,
        };

        if (index >= function_arg_regs.len) return error.TooManyArgs;
        return function_arg_regs[index];
    }

    pub fn regForFromIndex(self: @This(), index: usize, reg_type: RegisterType) ![]const u8 {
        const allocatable_regs = switch (reg_type) {
            .f => self.fp_allocatable_regs,
            .gp => self.gp_allocatable_regs,
            else => unreachable,
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

    pub fn scratchReg(self: @This(), index: usize, reg_type: RegisterType) ![]const u8 {
        switch (reg_type) {
            .f => {
                if (index >= self.fp_scratch_regs.len) return error.InvalidScratchReg;
                return self.fp_scratch_regs[index];
            },
            .gp => {
                if (index >= self.gp_scratch_regs.len) return error.InvalidScratchReg;
                return self.gp_scratch_regs[index];
            },
            else => unreachable,
        }
    }
};

fn mask(comptime width: usize, comptime shift: usize) u32 {
    return @intCast(((1 << width) - 1) << shift);
}
