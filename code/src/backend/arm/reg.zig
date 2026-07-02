const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const Abi = @import("../abi.zig").Abi;

// reserve two regs for scratch purposes
pub const scratch_reg = "x16";
pub const scratch_reg_2 = "x17";

/// function param registers
const function_param_regs = [_][]const u8{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7" };

/// callee save registers
const callee_save_regs = [_][]const u8{ "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28" };

/// caller save registers
/// in order to allow using x0-x7, we need to write percoloring code so that we dont have a collision
const caller_save_regs = [_][]const u8{ "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15" };

pub const ArmAbi = Abi.init(
    &function_param_regs,
    &caller_save_regs,
    &callee_save_regs,
    0,
);
