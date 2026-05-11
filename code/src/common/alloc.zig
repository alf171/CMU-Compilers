/// def/use/live_out view for register allocation
const std = @import("std");
const SpecialRegs = @import("ir.zig").SpecialRegs;
const TempId = @import("ir.zig").TempId;

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Writer = std.io.Writer;

pub const REG_COUNT = 8;

pub const Operands = struct {
    ops: std.array_list.Managed(Operand),

    pub fn toJoinedString(self: @This(), allocator: Allocator) ![]u8 {
        var list = std.array_list.Managed(u8).init(allocator);
        errdefer list.deinit();

        var first = true;
        for (self.ops.items) |op| {
            if (!first) try list.appendSlice(", ") else first = false;
            const s = try op.toString(allocator);
            defer allocator.free(s);
            try list.appendSlice(s);
        }
        return list.toOwnedSlice();
    }

    pub fn contains(self: @This(), op: Operand) bool {
        for (self.ops.items) |self_op| {
            if (Operand.equal(self_op, op)) {
                return true;
            }
        }
        return false;
    }

    /// return a new Operand removing op
    /// requires the elements being removed to be present
    pub fn remove(self: @This(), op: Operand, allocator: Allocator) !@This() {
        std.debug.assert(self.contains(op));
        var ops = std.array_list.Managed(Operand).init(allocator);
        for (self.ops.items) |loop_op| {
            if (!loop_op.equal(op)) {
                try ops.append(loop_op);
            }
        }
        return Operands{ .ops = ops };
    }

    pub fn clone(self: Operands, allocator: Allocator) !Operands {
        var new = Operands.init(allocator);
        for (self.ops.items) |item| {
            try new.ops.append(item);
        }
        return new;
    }

    pub fn init(allocator: Allocator) Operands {
        const ops = std.array_list.Managed(Operand).init(allocator);
        return Operands{ .ops = ops };
    }

    pub fn free(self: @This()) void {
        self.ops.deinit();
    }
};

pub const Operand = union(enum) {
    temp: TempId,
    spec_reg: SpecialRegs,
    mem: u8,

    pub fn equal(self: @This(), other: @This()) bool {
        return switch (self) {
            .temp => |t1| switch (other) {
                .temp => |t2| t1 == t2,
                else => false,
            },
            .spec_reg => |t1| switch (other) {
                .spec_reg => |t2| return t1 == t2,
                else => false,
            },
            .mem => |t1| switch (other) {
                .mem => |t2| return t1 == t2,
                else => false,
            },
        };
    }

    pub fn toString(op: @This(), allocator: std.mem.Allocator) ![]u8 {
        return switch (op) {
            .temp => |t| std.fmt.allocPrint(allocator, "%t{d}", .{t + 1}),
            .spec_reg => |s| std.fmt.allocPrint(allocator, "%{s}", .{@tagName(s)}),
            .mem => |t| std.fmt.allocPrint(allocator, "spill{d}", .{t + 1}),
        };
    }

    pub fn print(self: @This()) void {
        switch (self) {
            .temp => |id| std.debug.print("temp{d}", .{id}),
            .spec_reg => |reg| std.debug.print("%{s}", .{@tagName(reg)}),
            .mem => |id| std.debug.print("mem{d}", .{id}),
        }
    }
};

pub const AllocLine = struct {
    instruction_index: usize,
    uses: Operands,
    defines: Operands,
    live_out: Operands,
    move: bool,

    pub fn deinit(self: *@This()) void {
        self.uses.free();
        self.defines.free();
        self.live_out.free();
    }
};

pub const AllocProgram = struct {
    /// the lines being passed into the program
    lines: ArrayList(AllocLine),
    /// how many registers the program needs to utilize
    register_count: u8,

    pub fn deinit(self: *@This()) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
    }
};
