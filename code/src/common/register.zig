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

pub const RegisterClass = struct {
    type: RegisterType,
    width: u8,
};

pub const RegisterClasses = struct {
    map: std.AutoHashMap(Operand, RegisterClass),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .map = .init(alloc),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn put(self: *@This(), key: Operand, value: RegisterClass) !void {
        try self.map.put(key, value);
    }

    pub fn get(self: *const @This(), operand: Operand) !RegisterClass {
        return switch (operand) {
            .reg => |reg| .{
                .type = reg.type,
                .width = 1,
            },
            // HACK: we are going to give mem a register type
            .temp, .mem => self.map.get(operand) orelse return error.CantFindRegisterClass,
            else => unreachable,
        };
    }
};
