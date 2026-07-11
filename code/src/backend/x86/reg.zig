const std = @import("std");
const common = @import("common");
const ValueRef = common.ir.ValueRef;
const Abi = @import("../abi.zig").Abi;

const gp_scratch_reg = "r10";
const gp_scratch_reg_2 = "r11";

/// general purpose function param registers
const gp_function_param_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };

/// general purpose callee save registers
const gp_callee_save_regs = [_][]const u8{ "rbx", "r12", "r13", "r14", "r15" };

/// general purpose caller save registers
const gp_caller_save_regs = [_][]const u8{ "rax", "r10", "r11" };

const fp_scratch_reg = "xmm14";
const fp_scratch_reg_2 = "xmm15";

const fp_function_param_regs = [_][]const u8{
    "xmm0", "xmm1", "xmm2", "xmm3",
    "xmm4", "xmm5", "xmm6", "xmm7",
};

const fp_caller_save_regs = [_][]const u8{
    "xmm8",  "xmm9",  "xmm10",
    "xmm11", "xmm12", "xmm13",
};

const fp_callee_save_regs = [_][]const u8{};

pub const X86Abi = Abi.init(
    &gp_function_param_regs,
    &gp_caller_save_regs,
    &gp_callee_save_regs,
    6,
    &.{ gp_scratch_reg, gp_scratch_reg_2 },
    &fp_function_param_regs,
    &fp_caller_save_regs,
    &fp_callee_save_regs,
    6,
    &.{ fp_scratch_reg, gp_scratch_reg_2 },
);
