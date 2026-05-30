const std = @import("std");
const ArrayList = std.array_list.Managed;
const TypeInfo = @import("types.zig").TypeInfo;
const TypedOperand = @import("alloc.zig").TypedOperand;
const Operand = @import("alloc.zig").Operand;
const Block = @import("alloc.zig").AllocBlock;

pub const SpecialRegs = enum { eax };

const SpecRegsMap = std.StaticStringMap(SpecialRegs);
pub const spec_reg_map = SpecRegsMap.initComptime(.{
    .{ "eax", .eax },
});

pub const BlockId = u32;
// python defined variable
pub const LocalId = u32;
pub const LocalInfo = struct {
    id: LocalId,
    name: []const u8,
    type: ?TypeInfo,

    pub fn duplicate(self: @This(), alloc: std.mem.Allocator) !@This() {
        return LocalInfo{
            .id = self.id,
            .name = try alloc.dupe(u8, self.name),
            .type = self.type,
        };
    }
};
// compiler defined variable
pub const TempId = u8;

pub const BinOp = enum { add, sub, mul, div };

pub const UnaryOp = enum { neg };

pub const PhiInput = struct { pred: BlockId, value: Operand };

pub const LoopPhi = struct {
    local: LocalId,
    phi_inputs: []PhiInput,
    dst: TypedOperand,
};

pub const ConstValue = union(enum) {
    int: i64,
    bool: bool,
    float: f64,
    char: u8,
    bytes: []const u8,
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

pub const Instruction = union(enum) {
    store_local: struct {
        local: LocalInfo,
        src: Operand,
    },
    load_local: struct {
        dst: Operand,
        local: LocalInfo,
    },
    constant: struct {
        dst: Operand,
        value: ConstValue,
    },
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
    print: struct {
        src: Operand,
        type: TypeInfo,
    },
    jump: struct {
        target: BlockId,
    },
    branch: struct {
        condition: Operand,
        then_block: BlockId,
        else_block: BlockId,
    },
    phi: struct {
        dst: TypedOperand,
        inputs: []PhiInput,
    },
    // stack based fixed size array
    array_literal: struct {
        dst: Operand,
        elements: []Operand,
        type: TypeInfo,
    },
    // dst <- array[index]
    array_load: struct {
        dst: Operand,
        array: Operand,
        index: Operand,
        // TODO: changed array to TypedOperand?
        type: TypeInfo,
    },
    // heap based variable size
    list_literal: struct {
        dst: Operand,
        elements: []Operand,
        type: TypeInfo,
    },
    // dst <- list[index]
    list_load: struct {
        dst: Operand,
        list: Operand,
        index: Operand,
        // TODO: changed list to TypedOperand?
        type: TypeInfo,
    },
    unkown,
};

pub const BasicBlock = struct { id: BlockId, instructions: ArrayList(Instruction), successors: ArrayList(BlockId) };

pub const Program = struct {
    blocks: ArrayList(BasicBlock),

    pub fn init(alloc: std.mem.Allocator) Program {
        const blocks = ArrayList(BasicBlock).init(alloc);
        return Program{ .blocks = blocks };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            for (block.instructions.items) |*instruction| {
                switch (instruction.*) {
                    .constant => |c| {
                        if (c.value == .bytes) {
                            alloc.free(c.value.bytes);
                        }
                    },
                    .store_local => |sl| alloc.free(sl.local.name),
                    .load_local => |ll| alloc.free(ll.local.name),
                    .phi => |phi| {
                        alloc.free(phi.inputs);
                    },
                    else => {},
                }
            }
            block.instructions.deinit();
            block.successors.deinit();
        }
        self.blocks.deinit();
    }

    pub fn print(self: @This()) !void {
        for (self.blocks.items) |block| {
            std.debug.print("\nblock{d}:\n", .{block.id});

            for (block.instructions.items) |instruction| {
                std.debug.print("  ", .{});
                switch (instruction) {
                    .constant => |c| {
                        c.dst.print();
                        switch (c.value) {
                            .int => |value| {
                                std.debug.print(" <- {any}\n", .{value});
                            },
                            .bool => |value| {
                                std.debug.print(" <- {any}\n", .{value});
                            },
                            .char => |value| {
                                std.debug.print(" <- {any}\n", .{value});
                            },
                            .bytes => |value| {
                                std.debug.print(" <- {s}\n", .{value});
                            },
                            .float => {
                                return error.TypeNotImpl;
                            },
                        }
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
                        std.debug.print("\"{s}\" <- ", .{sl.local.name});
                        sl.src.print();
                        std.debug.print("\n", .{});
                    },
                    .load_local => |ll| {
                        ll.dst.print();
                        std.debug.print(" <- \"{s}\"\n", .{ll.local.name});
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
                    .print => |p| {
                        std.debug.print("print ", .{});
                        p.src.print();
                        std.debug.print("\n", .{});
                    },
                    .jump => |j| {
                        std.debug.print("jump block{d}\n", .{j.target});
                    },
                    .phi => |p| {
                        p.dst.operand.print();
                        std.debug.print(" <- phi (", .{});
                        for (p.inputs, 0..) |phi, i| {
                            if (i != 0) std.debug.print(", ", .{});
                            std.debug.print("block{d}: ", .{phi.pred});
                            phi.value.print();
                        }
                        std.debug.print(")\n", .{});
                    },
                    .branch => |b| {
                        b.condition.print();
                        std.debug.print(" ? jump block{d} : jump block{d}\n", .{ b.then_block, b.else_block });
                    },
                    .list_literal => |al| {
                        al.dst.print();
                        std.debug.print(" <- [", .{});
                        for (al.elements, 0..al.elements.len) |elem, i| {
                            if (i != 0) std.debug.print(", ", .{});
                            elem.print();
                        }
                        std.debug.print("]\n", .{});
                    },
                    .array_literal => |al| {
                        al.dst.print();
                        std.debug.print(" <- [", .{});
                        for (al.elements, 0..al.elements.len) |elem, i| {
                            if (i != 0) std.debug.print(", ", .{});
                            elem.print();
                        }
                        std.debug.print("]\n", .{});
                    },
                    .list_load => |al| {
                        al.dst.print();
                        std.debug.print(" <- ", .{});
                        al.list.print();
                        std.debug.print("[", .{});
                        al.index.print();
                        std.debug.print("]\n", .{});
                    },
                    .array_load => |al| {
                        al.dst.print();
                        std.debug.print(" <- ", .{});
                        al.array.print();
                        std.debug.print("[", .{});
                        al.index.print();
                        std.debug.print("]\n", .{});
                    },
                    else => |term| {
                        std.debug.panic("ir instruction not impl: {s}", .{@tagName(term)});
                        return error.NotImplemented;
                    },
                }
            }
        }
    }
};
