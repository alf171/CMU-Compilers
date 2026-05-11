const std = @import("std");
const ArrayList = std.array_list.Managed;
const Operand = @import("alloc.zig").Operand;

pub const SpecialRegs = enum { eax };

const SpecRegsMap = std.StaticStringMap(SpecialRegs);
pub const spec_reg_map = SpecRegsMap.initComptime(.{
    .{ "eax", .eax },
});

pub const BlockId = u32;
// python defined variable
pub const LocalId = u32;
// compiler defined variable
pub const TempId = u8;

pub const BinOp = enum { add, sub, mul, div };

pub const UnaryOp = enum { neg };

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

pub const Instruction = union(enum) {
    store_local: struct { local: LocalId, src: Operand },
    load_local: struct { dst: Operand, local: LocalId },
    constant: struct { dst: Operand, value: i64 },
    binop: struct {
        dst: Operand,
        op: BinOp,
        lhs: Operand,
        rhs: Operand,
    },
    move: struct { dst: Operand, src: Operand },
    unaryop: struct {
        dst: Operand,
        op: UnaryOp,
        src: Operand,
    },
    compare: struct {
        dst: Operand,
        op: CmpOp,
        lhs: Operand,
        rhs: Operand,
    },
    print_int: struct {
        src: Operand,
    },
    print_string: struct {
        src: []const u8,
    },
    jump: struct {
        target: BlockId,
    },
    branch: struct {
        condition: Operand,
        then_block: BlockId,
        else_block: BlockId,
    },
};

pub const BasicBlock = struct { id: BlockId, instructions: ArrayList(Instruction), successors: ArrayList(BlockId) };

pub const Program = struct {
    blocks: ArrayList(BasicBlock),

    pub fn init(alloc: std.mem.Allocator) Program {
        const blocks = ArrayList(BasicBlock).init(alloc);
        return Program{ .blocks = blocks };
    }

    pub fn deinit(self: *@This()) void {
        for (self.blocks.items) |*block| {
            block.instructions.deinit();
            block.successors.deinit();
        }
        self.blocks.deinit();
    }

    pub fn print(self: @This()) !void {
        for (self.blocks.items) |block| {
            std.debug.print("block{d}:\n", .{block.id});

            for (block.instructions.items) |instruction| {
                switch (instruction) {
                    .constant => |c| {
                        c.dst.print();
                        std.debug.print(" <- const {d}\n", .{c.value});
                    },
                    .binop => |binop| {
                        binop.dst.print();
                        std.debug.print(" <- {s} ", .{@tagName(binop.op)});
                        binop.lhs.print();
                        std.debug.print(", ", .{});
                        binop.rhs.print();
                        std.debug.print("\n", .{});
                    },
                    .store_local => |sl| {
                        std.debug.print("local{d} <- ", .{sl.local});
                        sl.src.print();
                        std.debug.print("\n", .{});
                    },
                    .load_local => |ll| {
                        ll.dst.print();
                        std.debug.print(" <- local{d}\n", .{ll.local});
                    },
                    .unaryop => |uop| {
                        uop.dst.print();
                        std.debug.print(" <- {s} ", .{@tagName(uop.op)});
                        uop.src.print();
                        std.debug.print("\n", .{});
                    },
                    .move => |m| {
                        m.dst.print();
                        std.debug.print(" <- ", .{});
                        m.src.print();
                        std.debug.print("\n", .{});
                    },
                    .compare => |c| {
                        c.dst.print();
                        std.debug.print(" <- ", .{});
                        c.lhs.print();
                        std.debug.print(" {s} ", .{c.op.symbol()});
                        c.rhs.print();
                        std.debug.print("\n", .{});
                    },
                    .print_int => |p| {
                        std.debug.print("print_int ", .{});
                        p.src.print();
                        std.debug.print("\n", .{});
                    },
                    .print_string => |p| {
                        std.debug.print("print_string {s}\n", .{p.src});
                    },
                    else => {
                        return error.NotImplemented;
                    },
                }
            }
        }
    }
};
