const std = @import("std");
const Instruction = @import("mir.zig").Instruction;
const ArrayList = std.ArrayList;
const TypeInfo = @import("types.zig").TypeInfo;
const TypedOperand = @import("alloc.zig").TypedOperand;
const Param = @import("alloc.zig").Param;
const Operand = @import("alloc.zig").Operand;

pub const SpecialRegs = enum { eax };

const SpecRegsMap = std.StaticStringMap(SpecialRegs);
pub const spec_reg_map = SpecRegsMap.initComptime(.{
    .{ "eax", .eax },
});

pub const SeenValue = union(enum) { operand: Operand, local: LocalId };

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

pub const BinOp = enum { add, sub, mul, div, mod, unknown };

pub const UnaryOp = enum { neg };

pub const ConstValue = union(enum) {
    int: i64,
    bool: bool,
    float: f64,
    char: u8,

    pub fn print(self: @This()) void {
        switch (self) {
            .int => |i| std.debug.print("{}", .{i}),
            .bool => |b| std.debug.print("{}", .{b}),
            .float => |f| std.debug.print("{}", .{f}),
            .char => |c| std.debug.print("{}", .{c}),
        }
    }
};

pub const LiteralElement = union(enum) {
    operand: Operand,
    constant: ConstValue,

    pub fn print(self: @This()) void {
        switch (self) {
            inline else => |value| value.print(),
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

    pub fn nextTemp(self: *@This()) Operand {
        const id = self.next_temp;
        self.next_temp += 1;
        return Operand{ .temp = .{
            .id = id,
            .function_id = self.id,
        } };
    }
};
