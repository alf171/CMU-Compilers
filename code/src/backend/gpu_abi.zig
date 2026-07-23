const std = @import("std");
const Operand = @import("common").alloc.Operand;
const ValueRef = @import("common").ir.ValueRef;
const ColoredGraph = @import("middle").color.ColoredGraph;
const TypeInfo = @import("common").types.TypeInfo;
const RegisterFile = @import("common").register.RegisterFile;
const RegisterType = @import("common").register.RegisterType;

pub const RegisterUsage = struct {
    vgpr_next: u16,
    sgpr_next: u16,
};

pub const GpuReg = struct {
    class: RegisterType,
    base: u16,
    width: u8,
};

pub const GpuAbi = struct {
    sgpr_allocatable_regs: []const u16,
    vgpr_allocatable_regs: []const u16,

    pub fn init(
        sgpr_allocatable_regs: []const u16,
        vgpr_allocatable_regs: []const u16,
    ) @This() {
        return .{
            .sgpr_allocatable_regs = sgpr_allocatable_regs,
            .vgpr_allocatable_regs = vgpr_allocatable_regs,
        };
    }

    fn regForFromIndex(self: @This(), index: usize, reg_type: RegisterType) !u16 {
        const allocatable_regs = switch (reg_type) {
            .vgpr => self.vgpr_allocatable_regs,
            .sgpr => self.sgpr_allocatable_regs,
            else => unreachable,
        };
        if (index >= allocatable_regs.len) return error.TooManyArgs;
        return allocatable_regs[index];
    }

    pub fn regFor(self: @This(), op: Operand, colors: *const ColoredGraph) !GpuReg {
        switch (op) {
            .temp => {
                const node = colors.nodes.get(op) orelse {
                    std.debug.print("Missing color for operand: ", .{});
                    op.print();
                    std.debug.print("\n", .{});
                    return error.MissingColor;
                };
                const reg_id = node.register orelse return error.MissingColor;
                const idx = try regForFromIndex(self, reg_id, node.reg_type);
                return .{
                    .class = node.reg_type,
                    .base = idx,
                    .width = 2,
                };
            },
            .reg => |reg| {
                return .{
                    .class = reg.class,
                    .base = reg.id,
                    .width = 2,
                };
            },
            else => return error.UnsupportedOperand,
        }
    }

    pub fn registerFiles(self: @This()) [2]RegisterFile {
        return .{
            .{
                .count = @intCast(self.vgpr_allocatable_regs.len),
                .type = .vgpr,
                .forbidden_mask = 0,
            },
            .{
                .count = @intCast(self.sgpr_allocatable_regs.len),
                .type = .sgpr,
                .forbidden_mask = 0,
            },
        };
    }

    pub fn registerUsage(self: @This(), colors: *const ColoredGraph) !RegisterUsage {
        var usage: RegisterUsage = .{
            // v0 is work-item id
            .vgpr_next = 1,
            //s[0:1] = kernarg pointer, s[2] work gorup
            .sgpr_next = 4,
        };

        var it = colors.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            const color = node.register orelse continue;

            const base = try self.regForFromIndex(color, node.reg_type);
            const next = base + 2;

            switch (node.reg_type) {
                .vgpr => usage.vgpr_next = @max(usage.vgpr_next, next),
                .sgpr => usage.sgpr_next = @max(usage.sgpr_next, next),
                else => unreachable,
            }
        }
        return usage;
    }
};
