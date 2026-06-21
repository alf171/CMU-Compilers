const std = @import("std");
const ArrayList = @import("std").ArrayList;
const debugPrint = @import("std").debug.print;
const LocalInfo = @import("ir.zig").LocalInfo;
const Operand = @import("alloc.zig").Operand;
const ConstValue = @import("ir.zig").ConstValue;
const LiteralElement = @import("ir.zig").LiteralElement;
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
        lhs: LiteralElement,
        rhs: LiteralElement,
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
    tuple_literal: struct {
        dst: TypedOperand,
        elements: []LiteralElement,
    },
    // dst <- array[index]
    tuple_load: struct {
        dst: Operand,
        tuple: TypedOperand,
        index: Operand,
    },
    // TODO: remove since tuples are immutable
    // array[index] <- src
    tuple_store: struct {
        tuple: TypedOperand,
        index: Operand,
        src: Operand,
    },
    // heap based variable size
    list_literal: struct {
        dst: TypedOperand,
        elements: []LiteralElement,
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
    // sys call [START]
    write: struct {
        fd: Operand,
        buf: TypedOperand,
        len: Operand,
    },
    // sys call [END]
    select: struct {
        dst: Operand,
        condition: Operand,
        if_value: LiteralElement,
        else_value: LiteralElement,
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
            .tuple_literal => |tl| {
                tl.dst.operand.print();
                debugPrint(" <- [", .{});
                for (tl.elements, 0..) |elem, i| {
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
            .tuple_store => |ts| {
                ts.tuple.operand.print();
                debugPrint("(", .{});
                ts.index.print();
                debugPrint(") <- ", .{});
                ts.src.print();
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
            .tuple_load => |tl| {
                tl.dst.print();
                debugPrint(" <- ", .{});
                tl.tuple.operand.print();
                debugPrint("(", .{});
                tl.index.print();
                debugPrint(")\n", .{});
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
            .write => |w| {
                debugPrint("write(", .{});
                w.fd.print();
                debugPrint(", ", .{});
                w.buf.operand.print();
                debugPrint(", ", .{});
                w.len.print();
                debugPrint(")\n", .{});
            },
            .select => |s| {
                s.dst.print();
                debugPrint(" <- ", .{});
                s.condition.print();
                debugPrint(" ? ", .{});
                s.if_value.print();
                debugPrint(" : ", .{});
                s.else_value.print();
                debugPrint("\n", .{});
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
                if (bop.lhs == .operand and bop.lhs.operand.equal(old)) {
                    bop.lhs.operand = new;
                }
                if (bop.rhs == .operand and bop.rhs.operand.equal(old)) {
                    bop.rhs.operand = new;
                }
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
                    switch (elem.*) {
                        .operand => |*op| {
                            if (op.equal(old)) op.* = new;
                        },
                        .constant => {},
                    }
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
            .tuple_load => |*tl| {
                if (tl.tuple.operand.equal(old)) tl.tuple.operand = new;
                if (tl.index.equal(old)) tl.index = new;
            },
            .tuple_literal => |*tl| {
                for (tl.elements) |*elem| {
                    switch (elem.*) {
                        .operand => |*op| {
                            if (op.equal(old)) op.* = new;
                        },
                        .constant => {},
                    }
                }
            },
            .tuple_store => |*ts| {
                if (ts.tuple.operand.equal(old)) ts.tuple.operand = new;
                if (ts.index.equal(old)) ts.index = new;
                if (ts.src.equal(old)) ts.src = new;
            },
            .function_call => |*fc| {
                for (fc.args) |*arg| {
                    if (arg.operand.equal(old)) arg.operand = new;
                }
            },
            .constant => {},
            .select => |*s| {
                if (s.condition.equal(old)) s.condition = new;
                if (s.if_value == .operand and s.if_value.operand.equal(old)) {
                    s.if_value.operand = new;
                }
                if (s.else_value == .operand and s.else_value.operand.equal(old)) {
                    s.else_value.operand = new;
                }
            },
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
            .tuple_load => |*tl| {
                if (tl.dst.equal(old)) tl.dst = new;
            },
            .constant => |*c| {
                if (c.dst.equal(old)) c.dst = new;
            },
            .tuple_literal => |*tl| {
                if (tl.dst.operand.equal(old)) tl.dst.operand = new;
            },
            .list_literal => |*ll| {
                if (ll.dst.operand.equal(old)) ll.dst.operand = new;
            },
            .select => |*s| {
                if (s.dst.equal(old)) s.dst = new;
            },
            .function_param => |*fc| {
                if (fc.dst.operand.equal(old)) fc.dst.operand = new;
            },
            else => |e| {
                debugPrint("defines cant handle {s}\n", .{@tagName(e)});
                return error.OperandReplaceNotImpl;
            },
        }
    }

    /// are we generating a new temp for reg coloring
    pub fn getDefines(instruction: Instruction) !?SeenValue {
        return switch (instruction) {
            .store_local => |sl| .{ .local = sl.local.id },
            .load_local => |ll| .{ .operand = ll.dst },
            .constant => |c| .{ .operand = c.dst },
            .binop => |bop| .{ .operand = bop.dst },
            .move => |m| .{ .operand = m.dst },
            .unaryop => |uop| .{ .operand = uop.dst },
            .compare => |c| .{ .operand = c.dst },
            .tuple_literal => |tl| .{ .operand = tl.dst.operand },
            .tuple_load => |tl| .{ .operand = tl.dst },
            .list_literal => |ll| .{ .operand = ll.dst.operand },
            .list_load => |ll| .{ .operand = ll.dst },
            .list_store => null,
            .select => |s| .{ .operand = s.dst },
            .function_call => |fc| if (fc.dst) |op| .{ .operand = op } else null,
            .function_param => |fp| .{ .operand = fp.dst.operand },
            .function_return => null,
            .write => null,
            .branch => null,
            .jump => null,
            else => |e| {
                std.debug.print("getDefines does not handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
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
                if (bop.lhs == .operand) {
                    try res.append(alloc, .{ .operand = bop.lhs.operand });
                }
                if (bop.rhs == .operand) {
                    try res.append(alloc, .{ .operand = bop.rhs.operand });
                }
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
            .tuple_literal => |tl| {
                for (tl.elements) |elem| {
                    switch (elem) {
                        .operand => |op| try res.append(alloc, .{ .operand = op }),
                        .constant => {},
                    }
                }
            },
            .tuple_load => |tl| {
                try res.append(alloc, .{ .operand = tl.tuple.operand });
                try res.append(alloc, .{ .operand = tl.index });
            },
            .tuple_store => |ts| {
                try res.append(alloc, .{ .operand = ts.tuple.operand });
                try res.append(alloc, .{ .operand = ts.index });
                try res.append(alloc, .{ .operand = ts.src });
            },
            .list_literal => |ll| {
                for (ll.elements) |elem| {
                    switch (elem) {
                        .operand => |op| try res.append(alloc, .{ .operand = op }),
                        .constant => {},
                    }
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
            .write => |w| {
                try res.append(alloc, .{ .operand = w.fd });
                try res.append(alloc, .{ .operand = w.buf.operand });
                try res.append(alloc, .{ .operand = w.len });
            },
            .select => |s| {
                try res.append(alloc, .{ .operand = s.condition });
                if (s.if_value == .operand) {
                    try res.append(alloc, .{ .operand = s.if_value.operand });
                }
                if (s.else_value == .operand) {
                    try res.append(alloc, .{ .operand = s.else_value.operand });
                }
            },
            .function_return => |fc| {
                if (fc.value) |op| {
                    try res.append(alloc, .{ .operand = op });
                }
            },
            .constant => {},
            .function_param => {},
            .jump => {},
            else => |e| {
                std.debug.print("getUses doesn't handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
        return res;
    }
};
