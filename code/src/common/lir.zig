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
    binop: struct {
        dst: TypedOperand,
        op: BinOp,
        lhs: TypedOperand,
        rhs: TypedOperand,
    },
    move: struct {
        dst: TypedOperand,
        // trying this out
        src: ValueRef,
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
    stack_alloc: struct {
        dst: TypedOperand,
        bytes: usize,
    },
    select: struct {
        dst: Operand,
        condition: Operand,
        if_value: ValueRef,
        else_value: ValueRef,
    },
    cast: struct {
        dst: Operand,
        dst_target_type: TypeInfo,
        src: TypedOperand,
    },
    unkown,

    pub fn printFn(self: @This()) !void {
        switch (self) {
            .binop => |binop| {
                binop.dst.operand.print();
                debugPrint(" <- {s} ", .{@tagName(binop.op)});
                binop.lhs.operand.print();
                debugPrint(", ", .{});
                binop.rhs.operand.print();
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
            .stack_alloc => |sa| {
                sa.dst.operand.print();
                debugPrint(" <- stack_alloc {d} bytes\n", .{sa.bytes});
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
            .cast => |c| {
                c.dst.print();
                debugPrint(" <- ({s})", .{@tagName(c.dst_target_type)});
                c.src.operand.print();
                debugPrint("\n", .{});
            },
            else => |term| {
                std.debug.panic("ir instruction not impl: {s}", .{@tagName(term)});
                return error.NotImplemented;
            },
        }
    }

    pub fn replaceUses(self: *@This(), old: Operand, new: Operand) void {
        switch (self.*) {
            .store_local => |*sl| {
                if (sl.src.equal(old)) sl.src = new;
            },
            .store_offset => |*so| {
                if (so.dst.operand.equal(old)) so.dst.operand = new;
                if (so.src.operand.equal(old)) so.src.operand = new;
                switch (so.offset) {
                    .top => |*top| {
                        if (top.operand.equal(old)) top.operand = new;
                    },
                    .constant => {},
                }
            },
            .load_offset => |*lo| {
                if (lo.src.operand.equal(old)) lo.src.operand = new;
                switch (lo.offset) {
                    .top => |*top| {
                        if (top.operand.equal(old)) top.operand = new;
                    },
                    .constant => {},
                }
            },
            .binop => |*bop| {
                if (bop.lhs.operand.equal(old)) {
                    bop.lhs.operand = new;
                }
                if (bop.rhs.operand.equal(old)) {
                    bop.rhs.operand = new;
                }
            },
            .move => |*mov| {
                switch (mov.src) {
                    .top => |*top| {
                        if (top.operand.equal(old)) top.operand = new;
                    },
                    .constant => {},
                }
            },
            .compare => |*c| {
                if (c.lhs.operand.equal(old)) c.lhs.operand = new;
                if (c.rhs.operand.equal(old)) c.rhs.operand = new;
            },
            .select => |*s| {
                if (s.condition.equal(old)) s.condition = new;
                switch (s.if_value) {
                    .top => |*top| {
                        if (top.operand.equal(old)) {
                            top.operand = new;
                        }
                    },
                    else => {},
                }
                switch (s.else_value) {
                    .top => |*top| {
                        if (top.operand.equal(old)) {
                            top.operand = new;
                        }
                    },
                    else => {},
                }
            },
            else => |e| {
                debugPrint("uses cant handle {s}\n", .{@tagName(e)});
                unreachable;
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
    pub fn getDefines(instruction: Instruction) ?SeenValue {
        return switch (instruction) {
            .store_local => |sl| .{ .local = sl.local.id },
            .load_local => |ll| .{ .operand = ll.dst },
            .binop => |bop| .{ .operand = bop.dst.operand },
            .move => |m| .{ .operand = m.dst.operand },
            .unaryop => |uop| .{ .operand = uop.dst.operand },
            .compare => |c| .{ .operand = c.dst.operand },
            .store_offset => null,
            .load_offset => |lo| .{ .operand = lo.dst.operand },
            .stack_alloc => |so| .{ .operand = so.dst.operand },
            .select => |s| .{ .operand = s.dst },
            .branch => null,
            .jump => null,
            .cast => |c| .{ .operand = c.dst },
            else => |e| {
                std.debug.print("getDefines does not handle {s}\n", .{@tagName(e)});
                unreachable;
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
                    .top => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
                try res.append(alloc, .{ .operand = so.src.operand });
            },
            .load_offset => |lo| {
                switch (lo.offset) {
                    .top => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
                try res.append(alloc, .{ .operand = lo.src.operand });
            },
            .stack_alloc => {},
            .load_local => |ll| {
                try res.append(alloc, .{ .local = ll.local.id });
            },
            .binop => |bop| {
                try res.append(alloc, .{ .operand = bop.lhs.operand });
                try res.append(alloc, .{ .operand = bop.rhs.operand });
            },
            .move => |m| {
                switch (m.src) {
                    .top => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    .constant => {},
                }
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
            .select => |s| {
                try res.append(alloc, .{ .operand = s.condition });
                switch (s.if_value) {
                    .top => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
                switch (s.else_value) {
                    .top => |top| {
                        try res.append(alloc, .{ .operand = top.operand });
                    },
                    else => {},
                }
            },
            .jump => {},
            .cast => |c| {
                try res.append(alloc, .{ .operand = c.src.operand });
            },
            else => |e| {
                std.debug.print("getUses doesn't handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
        return res;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .move => |m| {
                m.dst.type.deinit(alloc);
                switch (m.src) {
                    .top => |top| top.type.deinit(alloc),
                    .constant => {},
                }
            },
            .store_local => |sl| {
                alloc.free(sl.local.name);
            },
            .load_local => |ll| {
                alloc.free(ll.local.name);
            },
            .load_offset => |lo| {
                lo.dst.type.deinit(alloc);
                lo.src.type.deinit(alloc);
                switch (lo.offset) {
                    .top => |top| {
                        top.type.deinit(alloc);
                    },
                    .constant => {},
                }
            },
            .store_offset => |so| {
                so.dst.type.deinit(alloc);
                so.src.type.deinit(alloc);
                switch (so.offset) {
                    .top => |top| top.type.deinit(alloc),
                    .constant => {},
                }
            },
            .stack_alloc => |so| {
                so.dst.type.deinit(alloc);
            },
            else => {},
        }
    }
};
