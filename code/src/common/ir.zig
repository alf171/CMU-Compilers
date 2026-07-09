const std = @import("std");
const Instruction = @import("mir.zig").Instruction;
const ArrayList = std.ArrayList;
const TypeInfo = @import("types.zig").TypeInfo;
const TypedOperand = @import("alloc.zig").TypedOperand;
const Param = @import("alloc.zig").Param;
const Operand = @import("alloc.zig").Operand;

pub const SeenValue = union(enum) {
    operand: Operand,
    local: LocalId,
};

pub const RegisterType = union(enum) {
    /// general purpose register
    gp,
    /// floating point register
    f,
};

pub const PhysicalReg = struct {
    id: u8,
    class: RegisterType,
};

pub const BlockId = u32;
// python defined variable
pub const LocalId = u32;
pub const LocalInfo = struct {
    id: LocalId,
    name: []const u8,
    type: TypeInfo,

    pub fn duplicate(self: @This(), alloc: std.mem.Allocator) !@This() {
        return LocalInfo{
            .id = self.id,
            .name = try alloc.dupe(u8, self.name),
            .type = self.type,
        };
    }
};
// compiler defined variable
pub const TempId = u16;

/// we only permit 255 spills per program
pub const MemoryId = u8;

pub const BinOp = enum { add, sub, mul, div, mod, unknown };

pub const UnaryOp = enum { neg };

pub const ConstValue = union(enum) {
    i64: i64,
    i32: i32,
    bool: bool,
    float: f64,
    char: u8,

    pub fn print(self: @This()) void {
        switch (self) {
            .i64, .i32 => |i| std.debug.print("{d}", .{i}),
            .bool => |b| std.debug.print("{}", .{b}),
            .float => |f| std.debug.print("{}", .{f}),
            .char => |c| std.debug.print("{}", .{c}),
        }
    }

    /// return size in bytes
    pub fn size(self: @This()) usize {
        return switch (self) {
            .float, .i64 => 8,
            .i32 => 4,
            .bool, .char => 1,
        };
    }
};

pub const ValueRef = union(enum) {
    operand: TypedOperand,
    constant: ConstValue,

    pub fn print(self: @This()) void {
        switch (self) {
            .operand => |op| op.operand.print(),
            .constant => |c| c.print(),
        }
    }
};

pub const CmpOp = enum {
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,

    pub fn symbol(self: @This()) []const u8 {
        return switch (self) {
            .eq => "==",
            .neq => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
        };
    }
};

pub const BasicBlock = struct {
    id: BlockId,
    instructions: ArrayList(Instruction),
    successors: ArrayList(BlockId),

    pub fn init(id: BlockId) BasicBlock {
        return BasicBlock{
            .id = id,
            .instructions = .empty,
            .successors = .empty,
        };
    }
};

pub const Function = struct {
    name: []const u8,
    id: usize,
    params: []Param,
    return_type: TypeInfo,
    blocks: ArrayList(BasicBlock),
    entry_block: BlockId,
    next_temp: TempId,
    next_mem: MemoryId,

    pub fn nextTemp(self: *@This()) Operand {
        const id = self.next_temp;
        self.next_temp += 1;
        return Operand{ .temp = .{
            .id = id,
            .function_id = self.id,
        } };
    }

    pub fn nextMem(self: *@This()) Operand {
        const id = self.next_mem;
        self.next_mem += 1;
        return Operand{ .mem = .{
            .id = id,
            .function_id = self.id,
        } };
    }
};
