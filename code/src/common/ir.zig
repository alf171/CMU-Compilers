const std = @import("std");
const debugPrint = std.debug.print;
const ArrayList = std.ArrayList;
const TypeInfo = @import("types.zig").TypeInfo;
const TypedOperand = @import("alloc.zig").TypedOperand;
const Param = @import("alloc.zig").Param;
const Operand = @import("alloc.zig").Operand;
const Block = @import("alloc.zig").AllocBlock;

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

pub const Copy = struct { dst: Operand, src: Operand };

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
    move: struct {
        dst: Operand,
        src: Operand,
    },
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
    // [START] bultin functions
    print: struct {
        src: Operand,
        type: TypeInfo,
    },
    len: struct {
        dst: Operand,
        value: TypedOperand,
    },
    range: struct {
        dst: TypedOperand,
        start: TypedOperand,
        end: TypedOperand,
    },
    // [END] builtin functions
    jump: struct {
        target: BlockId,
    },
    branch: struct {
        condition: Operand,
        then_block: BlockId,
        else_block: BlockId,
    },
    // HIR ONLY
    phi: struct {
        dst: TypedOperand,
        inputs: []PhiInput,
    },
    // stack based fixed size array
    array_literal: struct {
        dst: TypedOperand,
        elements: []Operand,
    },
    // dst <- array[index]
    array_load: struct {
        dst: Operand,
        array: TypedOperand,
        index: Operand,
    },
    // array[index] <- src
    array_store: struct {
        array: TypedOperand,
        index: Operand,
        src: Operand,
    },
    // heap based variable size
    list_literal: struct {
        dst: TypedOperand,
        elements: []Operand,
    },
    // dst <- list[index]
    list_load: struct {
        dst: Operand,
        list: TypedOperand,
        index: Operand,
    },
    // list[index] <- src
    list_store: struct {
        list: TypedOperand,
        index: Operand,
        src: Operand,
    },
    function_call: struct {
        dst: ?Operand,
        function_name: []const u8,
        args: []TypedOperand,
    },
    function_return: struct {
        value: ?Operand,
    },
    function_param: struct {
        dst: TypedOperand,
        name: []const u8,
        index: usize,
    },
    // MIR ONLY
    parallel_copy: struct {
        copies: []Copy,
    },
    unkown,

    pub fn printFn(self: @This()) !void {
        switch (self) {
            .constant => |c| {
                c.dst.print();
                switch (c.value) {
                    .int => |value| {
                        debugPrint(" <- {any}\n", .{value});
                    },
                    .bool => |value| {
                        debugPrint(" <- {any}\n", .{value});
                    },
                    .char => |value| {
                        debugPrint(" <- {any}\n", .{value});
                    },
                    .bytes => |value| {
                        debugPrint(" <- {s}\n", .{value});
                    },
                    .float => {
                        return error.TypeNotImpl;
                    },
                }
            },
            .binop => |binop| {
                binop.dst.print();
                debugPrint(" <- {s} ", .{@tagName(binop.op)});
                binop.lhs.print();
                debugPrint(", ", .{});
                binop.rhs.print();
                debugPrint("\n", .{});
            },
            .store_local => |sl| {
                debugPrint("\"{s}\" <- ", .{sl.local.name});
                sl.src.print();
                debugPrint("\n", .{});
            },
            .load_local => |ll| {
                ll.dst.print();
                debugPrint(" <- \"{s}\"\n", .{ll.local.name});
            },
            .unaryop => |uop| {
                uop.dst.print();
                debugPrint(" <- {s} ", .{@tagName(uop.op)});
                uop.src.print();
                debugPrint("\n", .{});
            },
            .move => |m| {
                m.dst.print();
                debugPrint(" <- ", .{});
                m.src.print();
                debugPrint("\n", .{});
            },
            .compare => |c| {
                c.dst.print();
                debugPrint(" <- ", .{});
                c.lhs.print();
                debugPrint(" {s} ", .{c.op.symbol()});
                c.rhs.print();
                debugPrint("\n", .{});
            },
            .print => |p| {
                debugPrint("print ", .{});
                p.src.print();
                debugPrint("\n", .{});
            },
            .range => |r| {
                r.dst.operand.print();
                debugPrint(" <- range(", .{});
                r.start.operand.print();
                debugPrint(", ", .{});
                r.end.operand.print();
                debugPrint(")\n", .{});
            },
            .len => |l| {
                l.dst.print();
                debugPrint(" <- len(", .{});
                l.value.operand.print();
                debugPrint(")\n", .{});
            },
            .jump => |j| {
                debugPrint("jump block{d}\n", .{j.target});
            },
            .phi => |p| {
                p.dst.operand.print();
                debugPrint(" <- phi (", .{});
                for (p.inputs, 0..) |phi, i| {
                    if (i != 0) debugPrint(", ", .{});
                    debugPrint("block{d}: ", .{phi.pred});
                    phi.value.print();
                }
                debugPrint(")\n", .{});
            },
            .branch => |b| {
                b.condition.print();
                debugPrint(" ? jump block{d} : jump block{d}\n", .{ b.then_block, b.else_block });
            },
            .list_literal => |al| {
                al.dst.operand.print();
                debugPrint(" <- [", .{});
                for (al.elements, 0..) |elem, i| {
                    if (i != 0) debugPrint(", ", .{});
                    elem.print();
                }
                debugPrint("]\n", .{});
            },
            .array_literal => |al| {
                al.dst.operand.print();
                debugPrint(" <- [", .{});
                for (al.elements, 0..) |elem, i| {
                    if (i != 0) debugPrint(", ", .{});
                    elem.print();
                }
                debugPrint("]\n", .{});
            },
            .list_store => |ls| {
                ls.list.operand.print();
                debugPrint("[", .{});
                ls.index.print();
                debugPrint("] <- ", .{});
                ls.src.print();
                debugPrint("\n", .{});
            },
            .array_store => |as| {
                as.array.operand.print();
                debugPrint("[", .{});
                as.index.print();
                debugPrint("] <- ", .{});
                as.src.print();
                debugPrint("\n", .{});
            },
            .list_load => |al| {
                al.dst.print();
                debugPrint(" <- ", .{});
                al.list.operand.print();
                debugPrint("[", .{});
                al.index.print();
                debugPrint("]\n", .{});
            },
            .array_load => |al| {
                al.dst.print();
                debugPrint(" <- ", .{});
                al.array.operand.print();
                debugPrint("[", .{});
                al.index.print();
                debugPrint("]\n", .{});
            },
            .function_call => |fc| {
                if (fc.dst) |dst| {
                    dst.print();
                    debugPrint(" <- ", .{});
                }
                debugPrint("{s}(", .{fc.function_name});
                for (fc.args, 0..) |arg, i| {
                    if (i != 0) debugPrint(", ", .{});
                    arg.operand.print();
                }
                debugPrint(")\n", .{});
            },
            .function_return => |fr| {
                debugPrint("return ", .{});
                if (fr.value) |value| {
                    value.print();
                }
                debugPrint("\n", .{});
            },
            .function_param => |fp| {
                fp.dst.operand.print();
                debugPrint(" <- param {d}\n", .{fp.index});
            },
            .parallel_copy => |pc| {
                debugPrint("(", .{});
                for (pc.copies, 0..) |copy, i| {
                    if (i != 0) debugPrint(", ", .{});
                    copy.dst.print();
                }
                debugPrint(") <- ", .{});
                debugPrint("(", .{});
                for (pc.copies, 0..) |copy, i| {
                    if (i != 0) debugPrint(", ", .{});
                    copy.src.print();
                }
                debugPrint(")\n", .{});
            },
            else => |term| {
                std.debug.panic("ir instruction not impl: {s}", .{@tagName(term)});
                return error.NotImplemented;
            },
        }
    }

    pub fn replaceUses(self: *@This(), old: Operand, new: Operand) !void {
        switch (self.*) {
            .store_local => |*sl| {
                if (sl.src.equal(old)) sl.src = new;
            },
            .binop => |*bop| {
                if (bop.lhs.equal(old)) bop.lhs = new;
                if (bop.rhs.equal(old)) bop.rhs = new;
            },
            .move => |*mov| {
                if (mov.src.equal(old)) mov.src = new;
            },
            .list_load => |*ll| {
                if (ll.list.operand.equal(old)) ll.list.operand = new;
                if (ll.index.equal(old)) ll.index = new;
            },
            .list_literal => |*ll| {
                for (ll.elements) |*elem| {
                    if (elem.equal(old)) elem.* = new;
                }
            },
            .list_store => |*ls| {
                if (ls.list.operand.equal(old)) ls.list.operand = new;
                if (ls.index.equal(old)) ls.index = new;
                if (ls.src.equal(old)) ls.src = new;
            },
            .compare => |*c| {
                if (c.lhs.equal(old)) c.lhs = new;
                if (c.rhs.equal(old)) c.rhs = new;
            },
            .array_load => |*al| {
                if (al.array.operand.equal(old)) al.array.operand = new;
                if (al.index.equal(old)) al.index = new;
            },
            .array_literal => |*al| {
                for (al.elements) |*elem| {
                    if (elem.equal(old)) elem.* = new;
                }
            },
            .array_store => |*as| {
                if (as.array.operand.equal(old)) as.array.operand = new;
                if (as.index.equal(old)) as.index = new;
                if (as.src.equal(old)) as.src = new;
            },
            .function_call => |*fc| {
                for (fc.args) |*arg| {
                    if (arg.operand.equal(old)) arg.operand = new;
                }
            },
            .range => |*r| {
                if (r.start.operand.equal(old)) r.start.operand = new;
                if (r.end.operand.equal(old)) r.end.operand = new;
            },
            .len => |*l| {
                if (l.value.operand.equal(old)) l.value.operand = new;
            },
            .constant => {},
            else => |e| {
                debugPrint("uses cant handle {s}\n", .{@tagName(e)});
                return error.OperandReplaceNotImpl;
            },
        }
    }

    pub fn replaceDefines(self: *@This(), old: Operand, new: Operand) !void {
        switch (self.*) {
            .binop => |*bop| {
                if (bop.dst.equal(old)) bop.dst = new;
            },
            .move => |*mov| {
                if (mov.dst.equal(old)) mov.dst = new;
            },
            .list_load => |*ll| {
                if (ll.dst.equal(old)) ll.dst = new;
            },
            .compare => |*c| {
                if (c.dst.equal(old)) c.dst = new;
            },
            .array_load => |*al| {
                if (al.dst.equal(old)) al.dst = new;
            },
            .constant => |*c| {
                if (c.dst.equal(old)) c.dst = new;
            },
            .array_literal => |*al| {
                if (al.dst.operand.equal(old)) al.dst.operand = new;
            },
            .list_literal => |*ll| {
                if (ll.dst.operand.equal(old)) ll.dst.operand = new;
            },
            .range => |*r| {
                if (r.dst.operand.equal(old)) r.dst.operand = new;
            },
            .len => |*l| {
                if (l.dst.equal(old)) l.dst = new;
            },
            else => |e| {
                debugPrint("defines cant handle {s}\n", .{@tagName(e)});
                return error.OperandReplaceNotImpl;
            },
        }
    }

    pub fn getDefines(instruction: Instruction) ?SeenValue {
        return switch (instruction) {
            .store_local => |sl| .{ .local = sl.local.id },
            .load_local => |ll| .{ .operand = ll.dst },
            .constant => |c| .{ .operand = c.dst },
            .binop => |bop| .{ .operand = bop.dst },
            .move => |m| .{ .operand = m.dst },
            .unaryop => |uop| .{ .operand = uop.dst },
            .compare => |c| .{ .operand = c.dst },
            .phi => |pi| .{ .operand = pi.dst.operand },
            .array_literal => |al| .{ .operand = al.dst.operand },
            .array_load => |al| .{ .operand = al.dst },
            .list_literal => |ll| .{ .operand = ll.dst.operand },
            .list_load => |ll| .{ .operand = ll.dst },
            .range => |r| .{ .operand = r.dst.operand },
            else => null,
        };
    }

    pub fn getUses(instruction: Instruction, alloc: std.mem.Allocator) !ArrayList(SeenValue) {
        var res = ArrayList(SeenValue).empty;
        errdefer res.deinit(alloc);

        switch (instruction) {
            .store_local => |sl| {
                try res.append(alloc, .{ .operand = sl.src });
            },
            .load_local => |ll| {
                try res.append(alloc, .{ .local = ll.local.id });
            },
            .binop => |bop| {
                try res.append(alloc, .{ .operand = bop.lhs });
                try res.append(alloc, .{ .operand = bop.rhs });
            },
            .move => |m| {
                try res.append(alloc, .{ .operand = m.src });
            },
            .unaryop => |uop| {
                try res.append(alloc, .{ .operand = uop.src });
            },
            .compare => |c| {
                try res.append(alloc, .{ .operand = c.lhs });
                try res.append(alloc, .{ .operand = c.rhs });
            },
            .phi => |pi| {
                for (pi.inputs) |phi_input| {
                    try res.append(alloc, .{ .operand = phi_input.value });
                }
            },
            .print => |pi| {
                try res.append(alloc, .{ .operand = pi.src });
            },
            .range => |r| {
                try res.append(alloc, .{ .operand = r.start.operand });
                try res.append(alloc, .{ .operand = r.end.operand });
            },
            .len => |l| {
                try res.append(alloc, .{ .operand = l.value.operand });
            },
            .branch => |b| {
                try res.append(alloc, .{ .operand = b.condition });
            },
            .array_literal => |al| {
                for (al.elements) |elem| {
                    try res.append(alloc, .{ .operand = elem });
                }
            },
            .array_load => |al| {
                try res.append(alloc, .{ .operand = al.array.operand });
                try res.append(alloc, .{ .operand = al.index });
            },
            .array_store => |as| {
                try res.append(alloc, .{ .operand = as.array.operand });
                try res.append(alloc, .{ .operand = as.index });
                try res.append(alloc, .{ .operand = as.src });
            },
            .list_literal => |ll| {
                for (ll.elements) |elem| {
                    try res.append(alloc, .{ .operand = elem });
                }
            },
            .list_load => |il| {
                try res.append(alloc, .{ .operand = il.list.operand });
                try res.append(alloc, .{ .operand = il.index });
            },
            .list_store => |ls| {
                try res.append(alloc, .{ .operand = ls.list.operand });
                try res.append(alloc, .{ .operand = ls.index });
                try res.append(alloc, .{ .operand = ls.src });
            },
            .function_call => |fc| {
                for (fc.args) |arg| {
                    try res.append(alloc, .{ .operand = arg.operand });
                }
            },
            else => {},
        }
        return res;
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
    idx: usize,
    params: []Param,
    return_type: TypeInfo,
    blocks: ArrayList(BasicBlock),
    entry_block: BlockId,
    next_temp: TempId,
};

pub const Program = struct {
    main: Function,
    functions: ArrayList(Function),

    pub fn init(alloc: std.mem.Allocator) !Program {
        var blocks = ArrayList(BasicBlock).empty;
        const entry = BasicBlock.init(0);
        try blocks.append(alloc, entry);

        return Program{
            .main = Function{
                .name = "main",
                .idx = 0,
                .blocks = blocks,
                .entry_block = 0,
                .params = &.{},
                .return_type = .int,
                .next_temp = 0,
            },
            .functions = .empty,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.main.blocks.items) |*block| {
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
            block.instructions.deinit(alloc);
            block.successors.deinit(alloc);
        }
        self.main.blocks.deinit(alloc);
    }

    pub fn print(self: @This()) !void {
        for (self.functions.items) |function| {
            debugPrint("\n{s} -> {s}:\n", .{ function.name, @tagName(function.return_type) });
            for (function.blocks.items) |block| {
                debugPrint("block{d}:\n", .{block.id});

                for (block.instructions.items) |*instruction| {
                    debugPrint("  ", .{});
                    try instruction.printFn();
                }
            }
        }
        debugPrint("\n{s} -> {s}:\n", .{ self.main.name, @tagName(self.main.return_type) });
        for (self.main.blocks.items) |block| {
            debugPrint("block{d}:\n", .{block.id});

            for (block.instructions.items) |*instruction| {
                debugPrint("  ", .{});
                try instruction.printFn();
            }
        }
    }
};
