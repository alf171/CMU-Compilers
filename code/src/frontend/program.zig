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

        const entry = BasicBlock{
            .id = 0,
            .instructions = ArrayList(Instruction).init(alloc),
            .successors = ArrayList(BlockId).init(alloc)
        };

        try program.blocks.append(entry);

        return IrBuilder{
            .program = program,
            .current_block = 0,
            .next_local = 0,
            .next_temp = 0,
            .locals = ArrayList(LocalId).init(alloc)
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        for (self.program.blocks.items) |*block| {
            block.instructions.deinit();
            block.successor.deinit();
        }

        self.program.blocks.deinit();
        self.locals.deinit();
    }

    pub fn nextTemp(self: *@This()) Operand {
        const id = self.next_temp;
        self.next_temp += 1;
        return Operand{.temp = id };
    }

    pub fn emit(self: *@This(), instruct: Instruction) void {
        self.program.blocks.items[self.current_block].instructions.append(instruct);
    }
};

pub const Program = struct {
    blocks: ArrayList(BasicBlock),

    pub fn init(alloc: std.mem.Allocator) Program {
        const blocks = ArrayList(BasicBlock).init(alloc);
        return Program{.blocks = blocks };
    }
};

pub const BasicBlock = struct {
    id: BlockId,
    instructions: ArrayList(Instruction),
    successors: ArrayList(BlockId)
};

pub const Instruction = union(enum) {
    constant: struct {
        dst: Operand,
        value: i64
    },
    binop: struct {
        dst: Operand,
        op: BinOp,
        lhs: Operand,
        rhs: Operand,
    },
    move: struct {
        dst: Operand,
        src: Operand
    },
    jump: struct {
        target: BlockId
    }
    // TODO: branch
};

pub const Operand = union(enum) {
    temp: u8,
    spec_reg: SpecialRegs,
    mem: u8
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div
};

test "create ir builder" {
    const alloc = std.testing.allocator;
    const irBuilder = try IrBuilder.init(alloc);
    irBuilder.deinit();
}

