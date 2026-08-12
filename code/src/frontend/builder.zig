const std = @import("std");

const BlockId = @import("common").ir.BlockId;
const LocalId = @import("common").ir.LocalId;
const ClassId = @import("common").ir.ClassId;
const ClassInfo = @import("common").ir.ClassInfo;
const LocalInfo = @import("common").ir.LocalInfo;
const TempId = @import("common").ir.TempId;
const Function = @import("common").ir.Function;
const FunctionType = @import("common").ir.FunctionType;
const TypeInfo = @import("common").types.TypeInfo;
const TypeParam = @import("common").ir.TypeParam;

const BasicBlock = @import("common").ir.BasicBlock;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;

const ArrayList = std.ArrayList;
pub const LocalValues = std.AutoHashMap(LocalId, TypedOperand);

pub const IrBuilder = struct {
    program: Program,
    current_block: BlockId,
    current_function: ?usize,
    // name -> LocalId
    locals_by_name: std.StringHashMap(LocalId),
    // LocalId -> TypedOperand
    local_values: LocalValues,
    // LocalId -> LocalValues
    locals: ArrayList(LocalInfo),
    function_origin: FunctionType,
    active_param_types: []const TypeParam,

    pub fn init(origin: FunctionType, alloc: std.mem.Allocator) !IrBuilder {
        const program = try Program.init(alloc);

        return .{
            .program = program,
            .current_function = null,
            .current_block = 0,
            .locals_by_name = std.StringHashMap(LocalId).init(alloc),
            .local_values = LocalValues.init(alloc),
            .locals = .empty,
            .function_origin = origin,
            .active_param_types = &.{},
        };
    }

    /// free all but the generated program
    pub fn deinit(self: *IrBuilder, alloc: std.mem.Allocator) void {
        {
            var it = self.locals_by_name.keyIterator();
            while (it.next()) |key| {
                alloc.free(key.*);
            }
            self.locals_by_name.deinit();
        }
        IrBuilder.deinitLocalValues(&self.local_values, alloc);
        self.locals.deinit(alloc);
    }

    pub fn deinitLocalValues(local_values: *LocalValues, alloc: std.mem.Allocator) void {
        var it = local_values.valueIterator();
        while (it.next()) |value| {
            value.deinit(alloc);
        }
        local_values.deinit();
    }

    pub fn currentBlocks(self: *@This()) *ArrayList(BasicBlock) {
        const function = self.currentFunction();
        return &function.blocks;
    }

    pub fn currentFunction(self: *@This()) *Function {
        if (self.current_function) |i| {
            return &self.program.functions.items[i];
        }
        return &self.program.main;
    }

    pub fn nextTemp(self: *@This()) Operand {
        const function = self.currentFunction();
        return function.nextTemp();
    }

    pub fn nextFunctionId(self: *@This()) usize {
        return self.program.functions.items.len + 1;
    }

    pub fn nextClassIdx(self: *@This()) ClassId {
        return @intCast(self.program.classes.items.len);
    }

    /// O(function) scan looking for matching name
    pub fn findFunction(self: *@This(), name: []const u8) ?*Function {
        for (self.program.functions.items) |*function| {
            if (std.mem.eql(u8, function.name, name)) {
                return function;
            }
        }
        return null;
    }

    /// get function from index
    pub fn getFunction(self: *@This(), id: usize) ?*Function {
        if (id == 0 or id > self.program.functions.items.len) return null;
        return &self.program.functions.items[id - 1];
    }

    /// get class from index
    pub fn getClass(self: *@This(), class_id: ClassId) *ClassInfo {
        return &self.program.classes.items[class_id];
    }

    /// O(class) scan looking for matching name
    pub fn findClass(self: *@This(), name: []const u8) ?*ClassInfo {
        for (self.program.classes.items) |*class| {
            if (std.mem.eql(u8, class.name, name)) {
                return class;
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
        const id: LocalId = @intCast(self.locals.items.len);
        const owned_name = try alloc.dupe(u8, name);
        try self.locals_by_name.put(owned_name, id);
        try self.locals.append(alloc, .{
            .id = id,
            .name = owned_name,
            .type = typeInfo orelse .any,
        });
        return id;
    }

    pub fn emit(self: *@This(), instruct: Instruction, alloc: std.mem.Allocator) !void {
        const function = self.currentFunction();
        if (instruct.getDefines()) |defines| {
            switch (defines) {
                .top => |top| try function.setValueType(top.operand, top.type, alloc),
                .local => {},
            }
        }
        try self.currentBlocks().items[self.current_block].instructions.append(alloc, instruct);
    }

    pub fn newBlock(self: *@This(), alloc: std.mem.Allocator) !BlockId {
        const blocks = self.currentBlocks();
        const id: BlockId = @intCast(blocks.items.len);
        const new_block = BasicBlock.init(id);

        try blocks.append(alloc, new_block);
        return id;
    }

    pub fn setCurrentBlock(self: *@This(), id: BlockId) void {
        self.current_block = id;
    }

    pub fn addSuccessor(self: *@This(), from: BlockId, to: BlockId, alloc: std.mem.Allocator) !void {
        const current_block = self.currentBlocks();
        try current_block.items[to].predecessors.append(alloc, from);
        try current_block.items[from].successors.append(alloc, to);
    }

    pub fn cloneLocalValues(self: *@This(), alloc: std.mem.Allocator) !LocalValues {
        var cloned: LocalValues = .init(alloc);
        errdefer deinitLocalValues(&cloned, alloc);

        var it = self.local_values.iterator();
        while (it.next()) |entry| {
            const value = try entry.value_ptr.*.clone(alloc);
            cloned.put(entry.key_ptr.*, value) catch |err| {
                value.deinit(alloc);
                return err;
            };
        }

        return cloned;
    }

    pub fn restoreLocalValues(self: *@This(), locals: *const LocalValues, alloc: std.mem.Allocator) !void {
        self.clearLocalValues(alloc);

        var it = locals.iterator();
        while (it.next()) |entry| {
            const value = try entry.value_ptr.*.clone(alloc);
            self.local_values.put(entry.key_ptr.*, value) catch |err| {
                value.deinit(alloc);
                return err;
            };
        }
    }

    pub fn clearLocalValues(self: *@This(), alloc: std.mem.Allocator) void {
        var it = self.local_values.valueIterator();
        while (it.next()) |entry| {
            entry.deinit(alloc);
        }
        self.local_values.clearRetainingCapacity();
    }

    /// fetch the current functions type_param by its name
    pub fn getActiveParmType(self: *@This(), name: []const u8) ?TypeParam {
        for (self.active_param_types) |type_param| {
            if (std.mem.eql(u8, type_param.name, name)) {
                return type_param;
            }
        }
        return null;
    }
};

test "create ir builder" {
    const alloc = std.testing.allocator;
    var irBuilder = try IrBuilder.init(.user, alloc);
    defer irBuilder.deinit(alloc);
    defer irBuilder.program.deinit(alloc);

    const block = try irBuilder.newBlock(alloc);
    try std.testing.expectEqual(@as(BlockId, 1), block);
    try std.testing.expectEqual(@as(BlockId, 0), irBuilder.current_block);
}
