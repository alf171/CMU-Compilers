const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const Abi = @import("../abi.zig").Abi;

// reserve two regs for scratch purposes
const gp_scratch_reg = "x16";
const gp_scratch_reg_2 = "x17";

/// function param registers
const gp_function_param_regs = [_][]const u8{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7" };

/// callee save registers
const gp_callee_save_regs = [_][]const u8{ "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28" };

/// caller save registers
/// in order to allow using x0-x7, we need to write percoloring code so that we dont have a collision
const gp_caller_save_regs = [_][]const u8{ "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15" };

pub const fp_scratch_reg = "d16";

/// function param registers
const fp_function_param_regs = [_][]const u8{ "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7" };

/// callee save registers
const fp_callee_save_regs = [_][]const u8{ "d19", "d20", "d21", "d22", "d23", "d24", "d25", "d26", "d27", "d28" };

/// caller save registers
/// in order to allow using d0-d7, we need to write percoloring code so that we dont have a collision
const fp_caller_save_regs = [_][]const u8{ "d8", "d9", "d10", "d11", "d12", "d13", "d14", "d15" };

pub const ArmAbi = Abi.init(
    &gp_function_param_regs,
    &gp_caller_save_regs,
    &gp_callee_save_regs,
    0,
    &.{ gp_scratch_reg, gp_scratch_reg_2 },
    &fp_function_param_regs,
    &fp_caller_save_regs,
    &fp_callee_save_regs,
    0,
    &.{fp_scratch_reg},
);
