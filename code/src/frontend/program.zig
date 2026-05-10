const std = @import("std");
const SpecialRegs = @import("common").SpecialRegs;
const ArrayList = std.array_list.Managed;

pub const BlockId = u32;
// python defined variable
pub const LocalId = u32;
// compiler defined variable
pub const TempId = u32;

pub const IrBuilder = struct {
    program: Program,
    current_block: BlockId,
    next_local: LocalId,
    next_temp: TempId,
    locals: std.StringHashMap(LocalId),

    pub fn init(alloc: std.mem.Allocator) !IrBuilder {
        var program = Program.init(alloc);

        const entry = BasicBlock{ .id = 0, .instructions = ArrayList(Instruction).init(alloc), .successors = ArrayList(BlockId).init(alloc) };

        try program.blocks.append(entry);

        return IrBuilder{ .program = program, .current_block = 0, .next_local = 0, .next_temp = 0, .locals = std.StringHashMap(LocalId).init(alloc) };
    }

    /// free all but the generated program
    pub fn deinit(self: *IrBuilder, alloc: std.mem.Allocator) void {
        var it = self.locals.keyIterator();
        while (it.next()) |key| {
            alloc.free(key.*);
        }
        self.locals.deinit();
    }

    pub fn nextTemp(self: *@This()) Operand {
        const id = self.next_temp;
        self.next_temp += 1;
        return Operand{ .temp = id };
    }

    pub fn getOrCreateLocal(self: *@This(), name: []const u8, alloc: std.mem.Allocator) !LocalId {
        if (self.locals.get(name)) |local| {
            return local;
        }

        const local = self.next_local;
        const owned_name = try alloc.dupe(u8, name);
        try self.locals.put(owned_name, local);
        self.next_local += 1;
        return local;
    }

    pub fn emit(self: *@This(), instruct: Instruction) !void {
        try self.program.blocks.items[self.current_block].instructions.append(instruct);
    }
};

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

    pub fn print(self: @This()) void {
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
                }
            }
        }
    }
};

pub const BasicBlock = struct { id: BlockId, instructions: ArrayList(Instruction), successors: ArrayList(BlockId) };

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
    // TODO: jump
    // jump: struct {
    //     target: BlockId
    // }
    // TODO: branch
};

pub const Operand = union(enum) {
    temp: TempId,
    spec_reg: SpecialRegs,
    mem: u8,

    pub fn print(self: @This()) void {
        switch (self) {
            .temp => |id| std.debug.print("temp{d}", .{id}),
            .spec_reg => |reg| std.debug.print("%{s}", .{@tagName(reg)}),
            .mem => |id| std.debug.print("mem{d}", .{id}),
        }
    }
};

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

test "create ir builder" {
    const alloc = std.testing.allocator;
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    defer irBuilder.program.deinit();
}
