const std = @import("std");
const ArrayList = @import("std").ArrayList;
const debugPrint = @import("std").debug.print;
const LocalInfo = @import("ir.zig").LocalInfo;
const Operand = @import("alloc.zig").Operand;
const ConstValue = @import("ir.zig").ConstValue;
const ValueRef = @import("ir.zig").ValueRef;
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
        dst: TypedOperand,
        op: BinOp,
        lhs: ValueRef,
        rhs: ValueRef,
    },
    move: struct {
        dst: TypedOperand,
        src: Operand,
    },
    unaryop: struct {
        dst: TypedOperand,
        op: UnaryOp,
        src: Operand,
    },
    compare: struct {
        dst: TypedOperand,
        op: CmpOp,
        lhs: TypedOperand,
        rhs: TypedOperand,
    },
    jump: struct {
        target: BlockId,
    },
    branch: struct {
        condition: Operand,
        then_block: BlockId,
        else_block: BlockId,
    },
    // TODO: move into MIR
    // stack based fixed size array
    tuple_literal: struct {
        dst: TypedOperand,
        elements: []ValueRef,
    },
    // TODO: move into MIR
    // dst <- array[index]
    tuple_load: struct {
        dst: Operand,
        tuple: TypedOperand,
        index: Operand,
    },
    // TODO: move into MIR
    // TODO: remove since tuples are immutable
    // array[index] <- src
    tuple_store: struct {
        tuple: TypedOperand,
        index: Operand,
        src: Operand,
    },
    // dst <- *(src + offset)
    load_offset: struct {
        dst: TypedOperand,
        src: TypedOperand,
        offset: ValueRef,
    },
    // *(dst + offset) <- src
    store_offset: struct {
        dst: TypedOperand,
        /// offset in bytes
        offset: ValueRef,
        src: TypedOperand,
    },
    select: struct {
        dst: Operand,
        condition: Operand,
        if_value: ValueRef,
        else_value: ValueRef,
    },
    unkown,

    pub fn printFn(self: @This()) !void {
        switch (self) {
            .constant => |c| {
                c.dst.print();
                switch (c.value) {
                    .i64, .i32 => |value| {
                        debugPrint(" <- {d}\n", .{value});
                    },
                    .bool => |value| {
                        debugPrint(" <- {any}\n", .{value});
                    },
                    .char => |value| {
                        debugPrint(" <- {any}\n", .{value});
                    },
                    .float => |f| {
                        debugPrint(" <- {d}\n", .{f});
                    },
                }
            },
            .binop => |binop| {
                binop.dst.operand.print();
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
            .store_offset => |so| {
                debugPrint("*(", .{});
                so.dst.operand.print();
                debugPrint(" + ", .{});
                so.offset.print();
                debugPrint(") <- ", .{});
                so.src.operand.print();
                debugPrint("\n", .{});
            },
            .load_offset => |lo| {
                lo.dst.operand.print();
                debugPrint(" <- *(", .{});
                lo.src.operand.print();
                debugPrint(" + ", .{});
                lo.offset.print();
                debugPrint(")\n", .{});
            },
            .load_local => |ll| {
                ll.dst.print();
                debugPrint(" <- \"{s}\"\n", .{ll.local.name});
            },
            .unaryop => |uop| {
                uop.dst.operand.print();
                debugPrint(" <- {s} ", .{@tagName(uop.op)});
                uop.src.print();
                debugPrint("\n", .{});
            },
            .move => |m| {
                m.dst.operand.print();
                debugPrint(" <- ", .{});
                m.src.print();
                debugPrint("\n", .{});
            },
            .compare => |c| {
                c.dst.operand.print();
                debugPrint(" <- ", .{});
                c.lhs.operand.print();
                debugPrint(" {s} ", .{c.op.symbol()});
                c.rhs.operand.print();
                debugPrint("\n", .{});
            },
            .jump => |j| {
                debugPrint("jump block{d}\n", .{j.target});
            },
            .branch => |b| {
                b.condition.print();
                debugPrint(" ? jump block{d} : jump block{d}\n", .{ b.then_block, b.else_block });
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
            .tuple_store => |ts| {
                ts.tuple.operand.print();
                debugPrint("(", .{});
                ts.index.print();
                debugPrint(") <- ", .{});
                ts.src.print();
                debugPrint("\n", .{});
            },
            .tuple_load => |tl| {
                tl.dst.print();
                debugPrint(" <- ", .{});
                tl.tuple.operand.print();
                debugPrint("(", .{});
                tl.index.print();
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
            .store_offset => |*so| {
                if (so.src.operand.equal(old)) so.src.operand = new;
                switch (so.offset) {
                    .operand => |*top| {
                        if (top.operand.equal(old)) top.operand = new;
                    },
                    .constant => {},
                }
            },
            .load_offset => |*lo| {
                if (lo.src.operand.equal(old)) lo.src.operand = new;
                switch (lo.offset) {
                    .operand => |*top| {
                        if (top.operand.equal(old)) top.operand = new;
                    },
                    .constant => {},
                }
            },
            .binop => |*bop| {
                switch (bop.lhs) {
                    .operand => |*lop| {
                        if (lop.operand.equal(old)) {
                            lop.operand = new;
                        }
                    },
                    else => {},
                }
                switch (bop.rhs) {
                    .operand => |*rop| {
                        if (rop.operand.equal(old)) {
                            rop.operand = new;
                        }
                    },
                    else => {},
                }
            },
            .move => |*mov| {
                if (mov.src.equal(old)) mov.src = new;
            },
            .compare => |*c| {
                if (c.lhs.operand.equal(old)) c.lhs.operand = new;
                if (c.rhs.operand.equal(old)) c.rhs.operand = new;
            },
            .tuple_load => |*tl| {
                if (tl.tuple.operand.equal(old)) tl.tuple.operand = new;
                if (tl.index.equal(old)) tl.index = new;
            },
            .tuple_literal => |*tl| {
                for (tl.elements) |*elem| {
                    switch (elem.*) {
                        .operand => |*op| {
                            if (op.operand.equal(old)) op.*.operand = new;
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
            .constant => {},
            .select => |*s| {
                if (s.condition.equal(old)) s.condition = new;
                switch (s.if_value) {
                    .operand => |*iop| {
                        if (iop.operand.equal(old)) {
                            iop.operand = new;
                        }
                    },
                    else => {},
                }
                switch (s.else_value) {
                    .operand => |*eop| {
                        if (eop.operand.equal(old)) {
                            eop.operand = new;
                        }
                    },
                    else => {},
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
                if (bop.dst.operand.equal(old)) bop.dst.operand = new;
            },
            .move => |*mov| {
                if (mov.dst.operand.equal(old)) mov.dst.operand = new;
            },
            .compare => |*c| {
                if (c.dst.operand.equal(old)) c.dst.operand = new;
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
            .load_offset => |*lo| {
                if (lo.dst.operand.equal(old)) lo.dst.operand = new;
            },
            .select => |*s| {
                if (s.dst.equal(old)) s.dst = new;
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
            .binop => |bop| .{ .operand = bop.dst.operand },
            .move => |m| .{ .operand = m.dst.operand },
            .unaryop => |uop| .{ .operand = uop.dst.operand },
            .compare => |c| .{ .operand = c.dst.operand },
            .tuple_literal => |tl| .{ .operand = tl.dst.operand },
            .tuple_load => |tl| .{ .operand = tl.dst },
            .store_offset => null,
            .load_offset => |lo| .{ .operand = lo.dst.operand },
            .select => |s| .{ .operand = s.dst },
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
            .store_offset => |so| {
                try res.append(alloc, .{ .operand = so.dst.operand });
                switch (so.offset) {
                    .operand => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
                try res.append(alloc, .{ .operand = so.src.operand });
            },
            .load_offset => |lo| {
                switch (lo.offset) {
                    .operand => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
                try res.append(alloc, .{ .operand = lo.src.operand });
            },
            .load_local => |ll| {
                try res.append(alloc, .{ .local = ll.local.id });
            },
            .binop => |bop| {
                switch (bop.lhs) {
                    .operand => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
                switch (bop.rhs) {
                    .operand => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
            },
            .move => |m| {
                try res.append(alloc, .{ .operand = m.src });
            },
            .unaryop => |uop| {
                try res.append(alloc, .{ .operand = uop.src });
            },
            .compare => |c| {
                try res.append(alloc, .{ .operand = c.lhs.operand });
                try res.append(alloc, .{ .operand = c.rhs.operand });
            },
            .branch => |b| {
                try res.append(alloc, .{ .operand = b.condition });
            },
            .tuple_literal => |tl| {
                for (tl.elements) |elem| {
                    switch (elem) {
                        .operand => |op| try res.append(alloc, .{ .operand = op.operand }),
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
            .select => |s| {
                try res.append(alloc, .{ .operand = s.condition });
                switch (s.if_value) {
                    .operand => |if_op| {
                        try res.append(alloc, .{ .operand = if_op.operand });
                    },
                    else => {},
                }
                switch (s.else_value) {
                    .operand => |else_op| {
                        try res.append(alloc, .{ .operand = else_op.operand });
                    },
                    else => {},
                }
            },
            .constant => {},
            .jump => {},
            else => |e| {
                std.debug.print("getUses doesn't handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
        return res;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .tuple_literal => |tl| {
                tl.dst.type.deinit(alloc);
                alloc.free(tl.elements);
            },
            .store_local => |sl| {
                alloc.free(sl.local.name);
            },
            .load_local => |ll| {
                alloc.free(ll.local.name);
            },
            else => {},
        }
    }
};
