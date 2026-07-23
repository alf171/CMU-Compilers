pub const GpuAbi = @import("../gpu_abi.zig").GpuAbi;

// in order to support 64 bit data types, reserve to registers per color
const sgpr_allocatable_regs = [_]u16{
    4,
    6,
    8,
    10,
    12,
    14,
    16,
};
// v0 is work_items
const vgpr_allocatable_regs = [_]u16{
    1,
    3,
    5,
    7,
    9,
    11,
    13,
    15,
};

pub const Rdna3Abi = GpuAbi.init(&sgpr_allocatable_regs, &vgpr_allocatable_regs);
