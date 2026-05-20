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
pub const LocalValues = std.AutoHashMap(LocalId, Operand);

pub const IrBuilder = struct {
    program: Program,
    current_block: BlockId,
    next_block: BlockId,
    next_local: LocalId,
    next_temp: TempId,
    locals: std.StringHashMap(LocalId),
    local_values: LocalValues,

    pub fn init(alloc: std.mem.Allocator) !IrBuilder {
        var program = Program.init(alloc);

        const entry = BasicBlock{ .id = 0, .instructions = ArrayList(Instruction).init(alloc), .successors = ArrayList(BlockId).init(alloc) };

        try program.blocks.append(entry);

        return IrBuilder{
            .program = program,
            .current_block = 0,
            .next_block = 1,
            .next_local = 0,
            .next_temp = 0,
            .locals = std.StringHashMap(LocalId).init(alloc),
            .local_values = LocalValues.init(alloc),
        };
    }

    /// free all but the generated program
    pub fn deinit(self: *IrBuilder, alloc: std.mem.Allocator) void {
        var it = self.locals.keyIterator();
        while (it.next()) |key| {
            alloc.free(key.*);
        }
        self.locals.deinit();
        self.local_values.deinit();
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

    pub fn newBlock(self: *@This(), alloc: std.mem.Allocator) !BlockId {
        const id = self.next_block;
        self.next_block += 1;
        const new_block = BasicBlock{
            .id = id,
            .instructions = ArrayList(Instruction).init(alloc),
            .successors = ArrayList(BlockId).init(alloc),
        };

        try self.program.blocks.append(new_block);
        return id;
    }

    pub fn setCurrentBlock(self: *@This(), id: BlockId) void {
        self.current_block = id;
    }

    pub fn addSuccessor(self: *@This(), from: BlockId, to: BlockId) !void {
        try self.program.blocks.items[from].successors.append(to);
    }

    pub fn cloneLocalValues(self: *@This(), alloc: std.mem.Allocator) !LocalValues {
        return try self.local_values.cloneWithAllocator(alloc);
    }

    pub fn restoreLocalValues(self: *@This(), locals: *const LocalValues) !void {
        self.local_values.clearRetainingCapacity();

        var it = locals.iterator();
        while (it.next()) |entry| {
            try self.local_values.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

test "create ir builder" {
    const alloc = std.testing.allocator;
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    defer irBuilder.program.deinit(alloc);

    const block = try irBuilder.newBlock(alloc);
    try std.testing.expectEqual(@as(BlockId, 1), block);
    try std.testing.expectEqual(@as(BlockId, 0), irBuilder.current_block);
}
