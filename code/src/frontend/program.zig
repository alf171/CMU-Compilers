const std = @import("std");

const BlockId = @import("common").ir.BlockId;
const LocalId = @import("common").ir.LocalId;
const TempId = @import("common").ir.TempId;

const BasicBlock = @import("common").ir.BasicBlock;
const Operand = @import("common").alloc.Operand;
const Program = @import("common").ir.Program;
const Instruction = @import("common").ir.Instruction;
const SpecialRegs = @import("common").ir.SpecialRegs;

const ArrayList = std.array_list.Managed;

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

test "create ir builder" {
    const alloc = std.testing.allocator;
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    defer irBuilder.program.deinit();
}
