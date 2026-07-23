const std = @import("std");
const Operand = @import("alloc.zig").Operand;
// FIXME: be consistent between RegisterType and RegisterClass
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

// NOTE: eventually, we can push width into this for GPUs?
pub const RegisterOperand = struct {
    operand: Operand,
    register_type: RegisterType,
};

// pub const RegisterClasses = std.AutoHashMap(Operand, RegisterType);
pub const RegisterClasses = struct {
    map: std.AutoHashMap(Operand, RegisterType),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .map = std.AutoHashMap(Operand, RegisterType).init(alloc),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn put(self: *@This(), key: Operand, value: RegisterType) !void {
        try self.map.put(key, value);
    }

    pub fn get(self: *const @This(), operand: Operand) !RegisterType {
        return switch (operand) {
            .reg => |reg| reg.class,
            // HACK: we are going to give mem a register type
            .temp, .mem => self.map.get(operand) orelse return error.CantFindRegisterClass,
            else => unreachable,
        };
    }
};
