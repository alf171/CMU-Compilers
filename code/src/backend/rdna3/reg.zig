pub const GpuAbi = @import("../gpu_abi.zig").GpuAbi;

// in order to support 64 bit data types, reserve to registers per color
const sgpr_allocatable_regs = [_]u16{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
// v0 contains workgroup info
const vgpr_allocatable_regs = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
// scratch regs
const sgpr_scratch_regs = [_]u16{};
const vgpr_scratch_regs = [_]u16{ 16, 17 };

pub const Rdna3Abi = GpuAbi.init(&sgpr_allocatable_regs, &vgpr_allocatable_regs, &sgpr_scratch_regs, &vgpr_scratch_regs);
