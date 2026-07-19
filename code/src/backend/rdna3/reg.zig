pub const GpuAbi = @import("../gpu_abi.zig").GpuAbi;

const sgpr_allocatable_regs = [_][]const u8{ "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13", "s14", "s15", "s16", "s17" };
const vgpr_allocatable_regs = [_][]const u8{ "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17" };

pub const rdna3Abi = GpuAbi.init(sgpr_allocatable_regs, vgpr_allocatable_regs);
