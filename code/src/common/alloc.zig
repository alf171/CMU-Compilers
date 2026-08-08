/// def/use/live_out view for register allocation
const std = @import("std");
const PhysicalReg = @import("ir.zig").PhysicalReg;
const BlockId = @import("ir.zig").BlockId;
const ConstValue = @import("ir.zig").ConstValue;
const ParsedConstant = @import("ir.zig").ParsedConstant;
const TempId = @import("ir.zig").TempId;
const MemoryId = @import("ir.zig").MemoryId;
const Function = @import("ir.zig").Function;
const TypeInfo = @import("types.zig").TypeInfo;
const RegisterType = @import("register.zig").RegisterType;
const RegisterClass = @import("register.zig").RegisterClass;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;

pub const RegisterOperands = struct {
    ops: HashMap(Operand, RegisterClass),

    pub fn nextTemp(self: @This()) TempId {
        var max_temp: TempId = 0;

        var it = self.ops.keyIterator();
        while (it.next()) |op| {
            switch (op.*) {
                .temp => |t| max_temp = @max(max_temp, t.id + 1),
                else => {},
            }
        }
        return max_temp;
    }

    pub fn nextMem(self: @This()) MemoryId {
        var max_mem: MemoryId = 0;

        var it = self.ops.keyIterator();
        while (it.next()) |op| {
            switch (op.*) {
                .mem => |t| max_mem = @max(max_mem, t.id + 1),
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
        var res = RegisterOperands.init(alloc);
        var it = self.ops.iterator();
        while (it.next()) |entry| {
            const loop_op = entry.key_ptr.*;
            if (!loop_op.equal(op)) {
                try res.ops.put(loop_op, entry.value_ptr.*);
            }
        }
        return res;
    }

    pub fn clone(self: RegisterOperands, allocator: Allocator) !RegisterOperands {
        var res = RegisterOperands.init(allocator);
        var it = self.ops.iterator();
        while (it.next()) |entry| {
            try res.ops.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return res;
    }

    pub fn init(allocator: Allocator) RegisterOperands {
        const ops: std.AutoHashMap(Operand, RegisterClass) = .init(allocator);
        return .{ .ops = ops };
    }

    pub fn free(self: *@This()) void {
        self.ops.deinit();
    }

    pub fn add(self: *@This(), other: *const @This()) !void {
        var it = other.ops.iterator();
        while (it.next()) |entry| {
            try self.ops.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn single(self: @This()) !Operand {
        if (self.ops.count() != 1) {
            return error.ExpectedSingle;
        }
        var it = self.ops.keyIterator();
        return it.next().?.*;
    }

    pub fn singleForType(self: @This(), reg_type: RegisterType) !?Operand {
        var res: ?Operand = null;
        var it = self.ops.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.type != reg_type) continue;
            if (res != null) return error.ExpectedSingle;

            res = entry.key_ptr.*;
        }
        return res;
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

// value is scoped to ensure equality between blocks behaves
pub const ScopedTemp = struct {
    id: TempId,
    function_id: usize,

    fn equal(self: @This(), other: @This()) bool {
        return self.id == other.id and self.function_id == other.function_id;
    }
};

pub const ScopedMemory = struct {
    id: MemoryId,
    function_id: usize,

    pub fn equal(self: @This(), other: @This()) bool {
        return self.function_id == other.function_id and self.id == other.id;
    }
};

pub const Operand = union(enum) {
    temp: ScopedTemp,
    reg: PhysicalReg,
    mem: ScopedMemory,
    unknown,

    pub fn equal(self: @This(), other: @This()) bool {
        return switch (self) {
            .temp => |t1| switch (other) {
                .temp => |t2| t1.equal(t2),
                else => false,
            },
            .reg => |r1| switch (other) {
                .reg => |r2| return r1.equal(r2),
                else => false,
            },
            .mem => |t1| switch (other) {
                .mem => |t2| return t1.equal(t2),
                else => false,
            },
            .unknown => switch (other) {
                .unknown => return true,
                else => false,
            },
        };
    }

    pub fn sameOperand(self: @This(), other: ?@This()) bool {
        return if (other) |value| self.equal(value) else false;
    }

    pub fn toString(op: @This(), allocator: std.mem.Allocator) ![]u8 {
        return switch (op) {
            .temp => |t| std.fmt.allocPrint(allocator, "fid{d}:temp{d}", .{ t.function_id, t.id + 1 }),
            .reg => |r| std.fmt.allocPrint(allocator, "reg{d}", .{r.id}),
            .mem => |t| std.fmt.allocPrint(allocator, "spill{d}", .{t.id + 1}),
            else => return error.Unknown,
        };
    }

    pub fn print(self: @This()) void {
        switch (self) {
            .temp => |t| std.debug.print("temp{d}", .{t.id}),
            .reg => |r| std.debug.print("reg{d}", .{r.id}),
            .mem => |m| std.debug.print("mem{d}", .{m.id}),
            .unknown => std.debug.print("unknown", .{}),
        }
    }

    pub fn shouldColor(self: @This()) bool {
        return switch (self) {
            .temp, .reg => true,
            else => false,
        };
    }

    pub fn withFunctionId(self: @This(), function_id: usize) @This() {
        return switch (self) {
            .temp => |temp| .{ .temp = .{
                .id = temp.id,
                .function_id = function_id,
            } },
            .mem => |mem| .{ .mem = .{
                .id = mem.id,
                .function_id = function_id,
            } },
            .reg, .unknown => self,
        };
    }
};

pub const TypedOperand = struct {
    operand: Operand,
    /// type snapshot
    type: TypeInfo,

    /// current type following aliases
    pub fn getType(self: @This(), function: *const Function) !*const TypeInfo {
        return function.value_to_type.getPtr(self.operand) orelse {
            return error.TypeNotFound;
        };
    }

    pub fn equal(self: @This(), other: @This()) bool {
        return self.operand.equal(other.operand);
    }

    /// clone type since it can be heap allocated
    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {
        return .{ .operand = self.operand, .type = try self.type.clone(alloc) };
    }

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        self.type.deinit(alloc);
    }
};

pub const AllocLine = struct {
    instruction_index: usize,
    uses: RegisterOperands,
    defines: RegisterOperands,
    live_out: RegisterOperands,
    move: bool,
    // marks if an operation triggers a br; this indicates that caller saved
    // register will get cloberred and thus we must color differently
    clobber_caller_saved: bool,

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
    predecessors: ArrayList(BlockId),
    successors: ArrayList(BlockId),
    // needed to make temps unique
    function_id: usize,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.predecessors.deinit(alloc);
        self.successors.deinit(alloc);
    }
};

pub const AllocProgram = struct {
    /// the lines being passed into the program
    lines: ArrayList(AllocLine),
    /// track register allocation w.r.t to the control flow
    blocks: ArrayList(AllocBlock),

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        for (self.blocks.items) |*block| {
            block.deinit(alloc);
        }
        self.lines.deinit(alloc);
        self.blocks.deinit(alloc);
    }

    pub fn nextTemp(self: @This()) TempId {
        var next_temp: TempId = 0;
        for (self.lines.items) |line| {
            next_temp = @max(next_temp, line.uses.nextTemp());
            next_temp = @max(next_temp, line.defines.nextTemp());
            next_temp = @max(next_temp, line.live_out.nextTemp());
        }
        return next_temp;
    }

    pub fn nextMem(self: @This()) MemoryId {
        var next_mem: MemoryId = 0;
        for (self.lines.items) |line| {
            next_mem = @max(next_mem, line.uses.nextMem());
            next_mem = @max(next_mem, line.defines.nextMem());
            next_mem = @max(next_mem, line.live_out.nextMem());
        }
        return next_mem;
    }

    /// O(n) scan for block
    pub fn getBlockById(self: *const @This(), id: BlockId, function_id: usize) !AllocBlock {
        for (self.blocks.items) |block| {
            if (block.id == id and block.function_id == function_id) return block;
        }
        return error.BlockNotFound;
    }
};

pub const WorkList = struct {
    work_list: ArrayList(BlockId),
    in_worklist: []bool,

    pub fn init(block_count: usize, alloc: std.mem.Allocator) !@This() {
        const in_work_list = try alloc.alloc(bool, block_count);
        @memset(in_work_list, false);

        return .{
            .work_list = .empty,
            .in_worklist = in_work_list,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.work_list.deinit(alloc);
        alloc.free(self.in_worklist);
    }

    pub fn enqueue(self: *@This(), id: BlockId, alloc: std.mem.Allocator) !void {
        if (!self.in_worklist[id]) {
            try self.work_list.append(alloc, id);
            self.in_worklist[id] = true;
        }
    }

    pub fn pop(self: *@This()) ?BlockId {
        const id = self.work_list.pop() orelse return null;
        self.in_worklist[id] = false;
        return id;
    }
};

test "operands equal" {
    const alloc = std.testing.allocator;
    var ops1 = HashMap(Operand, RegisterType).init(alloc);
    defer ops1.deinit();
    try ops1.put(.{ .temp = .{ .id = 99, .function_id = 0 } }, .gp);
    var a: RegisterOperands = .{ .ops = ops1 };

    var ops2 = HashMap(Operand, RegisterType).init(alloc);
    defer ops2.deinit();
    try ops2.put(Operand{ .temp = .{ .id = 99, .function_id = 0 } }, .gp);
    const b: RegisterOperands = .{ .ops = ops2 };

    try std.testing.expect(b.equal(&a));
    try std.testing.expect(a.equal(&b));

    try a.ops.put(.{ .temp = .{ .id = 100, .function_id = 0 } }, .gp);
    try std.testing.expect(!a.equal(&b));
}
