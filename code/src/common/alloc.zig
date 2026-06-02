/// def/use/live_out view for register allocation
const std = @import("std");
const SpecialRegs = @import("ir.zig").SpecialRegs;
const BlockId = @import("ir.zig").BlockId;
const TempId = @import("ir.zig").TempId;
const TypeInfo = @import("types.zig").TypeInfo;

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const HashMap = std.AutoHashMap;
const Writer = std.io.Writer;

pub const REG_COUNT = 8;

pub const Operands = struct {
    ops: HashMap(Operand, void),

    pub fn nextTemp(self: @This()) u8 {
        var max_temp: u8 = 0;

        var it = self.ops.keyIterator();
        while (it.next()) |op| {
            switch (op.*) {
                .temp => |t| max_temp = @max(max_temp, t + 1),
                else => {},
            }
        }
        return max_temp;
    }

    pub fn nextMem(self: @This()) u8 {
        var max_mem: u8 = 0;

        var it = self.ops.keyIterator();
        while (it.next()) |op| {
            switch (op.*) {
                .mem => |t| max_mem = @max(max_mem, t + 1),
                else => {},
            }
        }
        return max_mem;
    }

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

    /// return a new Operand removing op
    /// requires the elements being removed to be present
    pub fn remove(self: @This(), op: Operand, alloc: Allocator) !@This() {
        std.debug.assert(self.ops.contains(op));
        var res = Operands.init(alloc);
        var it = self.ops.keyIterator();
        while (it.next()) |loop_op| {
            if (!loop_op.equal(op)) {
                try res.ops.put(loop_op.*, {});
            }
        }
        return res;
    }

    pub fn clone(self: Operands, allocator: Allocator) !Operands {
        var res = Operands.init(allocator);
        var it = self.ops.keyIterator();
        while (it.next()) |item| {
            try res.ops.put(item.*, {});
        }
        return res;
    }

    pub fn init(allocator: Allocator) Operands {
        const ops = std.AutoHashMap(Operand, void).init(allocator);
        return Operands{ .ops = ops };
    }

    pub fn free(self: *@This()) void {
        self.ops.deinit();
    }

    pub fn add(self: *@This(), other: *const @This()) !void {
        var it = other.ops.keyIterator();
        while (it.next()) |op| {
            try self.ops.put(op.*, {});
        }
    }

    pub fn single(self: @This()) !Operand {
        if (self.ops.count() != 1) {
            return error.ExpectedSingle;
        }
        var it = self.ops.keyIterator();
        return it.next().?.*;
    }

    pub fn equal(self: *const @This(), other: *const @This()) bool {
        if (self.ops.count() != other.ops.count()) return false;

        var it = self.ops.keyIterator();
        while (it.next()) |op| {
            if (!other.ops.contains(op.*)) return false;
        }
        return true;
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

    pub fn sameOperand(self: @This(), other: ?@This()) bool {
        return if (other) |value| self.equal(value) else false;
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

pub const Param = struct {
    name: []const u8,
    type: TypeInfo,
};

pub const TypedOperand = struct {
    operand: Operand,
    type: TypeInfo,

    pub fn equal(self: @This(), other: @This()) bool {
        return self.operand.equal(other.operand);
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

pub const AllocBlock = struct {
    id: u32,
    start: usize,
    /// exclusive
    end: usize,
    successors: ArrayList(BlockId),

    pub fn deinit(self: *@This()) void {
        self.successors.deinit();
    }
};

pub const AllocProgram = struct {
    /// the lines being passed into the program
    lines: ArrayList(AllocLine),
    /// track register allocation w.r.t to the control flow
    blocks: ArrayList(AllocBlock),
    /// how many registers the program needs to utilize
    register_count: u8,

    pub fn deinit(self: *@This()) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        for (self.blocks.items) |*block| {
            block.deinit();
        }
        self.lines.deinit();
        self.blocks.deinit();
    }

    pub fn nextTemp(self: @This()) u8 {
        var next_temp: u8 = 0;
        for (self.lines.items) |line| {
            next_temp = @max(next_temp, line.uses.nextTemp());
            next_temp = @max(next_temp, line.defines.nextTemp());
            next_temp = @max(next_temp, line.live_out.nextTemp());
        }
        return next_temp;
    }

    pub fn nextMem(self: @This()) u8 {
        var next_mem: u8 = 0;
        for (self.lines.items) |line| {
            next_mem = @max(next_mem, line.uses.nextMem());
            next_mem = @max(next_mem, line.defines.nextMem());
            next_mem = @max(next_mem, line.live_out.nextMem());
        }
        return next_mem;
    }

    pub fn getBlockById(self: *const @This(), id: BlockId) !AllocBlock {
        for (self.blocks.items) |block| {
            if (block.id == id) return block;
        }
        return error.BlockNotFound;
    }
};

test "operands equal" {
    const alloc = std.testing.allocator;
    var ops1 = HashMap(Operand, void).init(alloc);
    defer ops1.deinit();
    try ops1.put(Operand{ .temp = 99 }, {});
    var a = Operands{ .ops = ops1 };

    var ops2 = HashMap(Operand, void).init(alloc);
    defer ops2.deinit();
    try ops2.put(Operand{ .temp = 99 }, {});
    const b = Operands{ .ops = ops2 };

    try std.testing.expect(b.equal(&a));
    try std.testing.expect(a.equal(&b));

    try a.ops.put(Operand{ .temp = 100 }, {});
    try std.testing.expect(!a.equal(&b));
}
