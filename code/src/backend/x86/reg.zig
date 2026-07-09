const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const Abi = @import("../abi.zig").Abi;

pub const scratch_reg = "r10";
pub const scratch_reg_2 = "r11";

/// function param registers
const function_param_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };

/// callee save registers
const callee_save_regs = [_][]const u8{ "rbx", "r12", "r13", "r14", "r15" };

/// caller save registers
const caller_save_regs = [_][]const u8{ "rax", "r10", "r11" };

pub const X86Abi = Abi.init(
    &function_param_regs,
    &caller_save_regs,
    &callee_save_regs,
    6,
    // FIXME: this is wrong
    &function_param_regs,
    &caller_save_regs,
    &callee_save_regs,
    6,
);
