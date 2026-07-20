pub const RegisterType = enum {
    /// general purpose register
    gp,
    /// floating point register
    f,
    /// scalar general purpose register
    sgpr,
    /// vector general purpose register
    vgpr,
};

pub const RegisterFile = struct {
    count: u16,
    type: RegisterType,
    forbidden_mask: u32,
};
