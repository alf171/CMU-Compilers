const std = @import("std");
const ArrayList = @import("std").ArrayList;
const debugPrint = @import("std").debug.print;
const LocalInfo = @import("ir.zig").LocalInfo;
const Operand = @import("alloc.zig").Operand;
const ConstValue = @import("ir.zig").ConstValue;
const BinOp = @import("ir.zig").BinOp;
const BlockId = @import("ir.zig").BlockId;
const CmpOp = @import("ir.zig").CmpOp;
const UnaryOp = @import("ir.zig").UnaryOp;
const SeenValue = @import("ir.zig").SeenValue;
const TypeInfo = @import("types.zig").TypeInfo;
const TypedOperand = @import("alloc.zig").TypedOperand;

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
    jump: struct {
        target: BlockId,
    },
    branch: struct {
        condition: Operand,
        then_block: BlockId,
        else_block: BlockId,
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
            .jump => |j| {
                debugPrint("jump block{d}\n", .{j.target});
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
            .array_literal => |al| .{ .operand = al.dst.operand },
            .array_load => |al| .{ .operand = al.dst },
            .list_literal => |ll| .{ .operand = ll.dst.operand },
            .list_load => |ll| .{ .operand = ll.dst },
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
