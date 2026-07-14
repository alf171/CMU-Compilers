const std = @import("std");

const BlockId = @import("common").ir.BlockId;
const LocalId = @import("common").ir.LocalId;
const LocalInfo = @import("common").ir.LocalInfo;
const TempId = @import("common").ir.TempId;
const Function = @import("common").ir.Function;
const FunctionType = @import("common").ir.FunctionType;
const TypeInfo = @import("common").types.TypeInfo;

const BasicBlock = @import("common").ir.BasicBlock;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const SpecialRegs = @import("common").ir.SpecialRegs;

const ArrayList = std.ArrayList;
pub const LocalValues = std.AutoHashMap(LocalId, TypedOperand);

pub const IrBuilder = struct {
    program: Program,
    current_block: BlockId,
    current_function: ?usize,
    next_block: BlockId,
    next_local: LocalId,
    // TODO: dont use usize
    next_function_idx: usize,
    // name -> LocalId
    locals_by_name: std.StringHashMap(LocalId),
    // LocalId -> TypedOperand
    local_values: LocalValues,
    // LocalId -> LocalValues
    locals: ArrayList(LocalInfo),
    function_origin: FunctionType,

    pub fn init(origin: FunctionType, alloc: std.mem.Allocator) !IrBuilder {
        const program = try Program.init(alloc);

        return IrBuilder{
            .program = program,
            .current_function = null,
            .current_block = 0,
            .next_block = 1,
            .next_local = 0,
            .next_function_idx = 1,
            .locals_by_name = std.StringHashMap(LocalId).init(alloc),
            .local_values = LocalValues.init(alloc),
            .locals = .empty,
            .function_origin = origin,
        };
    }

    /// free all but the generated program
    pub fn deinit(self: *IrBuilder, alloc: std.mem.Allocator) void {
        var it = self.locals_by_name.keyIterator();
        while (it.next()) |key| {
            alloc.free(key.*);
        }
        self.locals_by_name.deinit();
        self.local_values.deinit();
        self.locals.deinit(alloc);
    }

    pub fn currentBlocks(self: *@This()) *ArrayList(BasicBlock) {
        if (self.current_function) |i| {
            return &self.program.functions.items[i].blocks;
        }
        return &self.program.main.blocks;
    }

    pub fn currentFunction(self: *@This()) !*Function {
        if (self.current_function) |i| {
            return &self.program.functions.items[i];
        }
        return error.CantFindCurrentFunction;
    }

    pub fn nextTemp(self: *@This()) Operand {
        const function = self.currentFunction() catch &self.program.main;
        return function.nextTemp();
    }

    pub fn nextFunctionIdx(self: *@This()) usize {
        const idx = self.next_function_idx;
        self.next_function_idx += 1;
        return idx;
    }

    // O(function) scan looking for matching name
    pub fn findFunction(self: *@This(), name: []const u8) ?*Function {
        for (self.program.functions.items) |*function| {
            if (std.mem.eql(u8, function.name, name)) {
                return function;
            }
        }
        return null;
    }

    pub fn getLocal(self: *@This(), name: []const u8) !LocalId {
        if (self.locals_by_name.get(name)) |local| {
            return local;
        }
        return error.CantFindLocal;
    }

    pub fn getOrCreateLocal(self: *@This(), name: []const u8, typeInfo: ?TypeInfo, alloc: std.mem.Allocator) !LocalId {
        // already existed
        if (self.locals_by_name.get(name)) |local| {
            return local;
        }
        // needs to get created
        const id = self.next_local;
        const owned_name = try alloc.dupe(u8, name);
        try self.locals_by_name.put(owned_name, id);
        try self.locals.append(alloc, LocalInfo{
            .id = id,
            .name = owned_name,
            .type = typeInfo orelse .any,
        });
        self.next_local += 1;
        return id;
    }

    pub fn emit(self: *@This(), instruct: Instruction, alloc: std.mem.Allocator) !void {
        try self.currentBlocks().items[self.current_block].instructions.append(alloc, instruct);
    }

    pub fn newBlock(self: *@This(), alloc: std.mem.Allocator) !BlockId {
        const id = self.next_block;
        self.next_block += 1;
        const new_block = BasicBlock{
            .id = id,
            .instructions = .empty,
            .successors = .empty,
        };

        try self.currentBlocks().append(alloc, new_block);
        return id;
    }

    pub fn setCurrentBlock(self: *@This(), id: BlockId) void {
        self.current_block = id;
    }

    pub fn addSuccessor(self: *@This(), from: BlockId, to: BlockId, alloc: std.mem.Allocator) !void {
        try self.currentBlocks().items[from].successors.append(alloc, to);
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
