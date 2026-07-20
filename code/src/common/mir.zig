const std = @import("std");
const ArrayList = @import("std").ArrayList;
const debugPrint = std.debug.print;
const LocalInfo = @import("ir.zig").LocalInfo;
const Operand = @import("alloc.zig").Operand;
const ConstValue = @import("ir.zig").ConstValue;
const BinOp = @import("ir.zig").BinOp;
const BlockId = @import("ir.zig").BlockId;
const LocalId = @import("ir.zig").LocalId;
const CmpOp = @import("ir.zig").CmpOp;
const UnaryOp = @import("ir.zig").UnaryOp;
const SeenValue = @import("ir.zig").SeenValue;
const ValueRef = @import("ir.zig").ValueRef;
const TypedOperand = @import("alloc.zig").TypedOperand;
const TypeInfo = @import("types.zig").TypeInfo;
const LirInstruction = @import("lir.zig").Instruction;

pub const PhiInput = struct { pred: BlockId, value: TypedOperand };

pub const Copy = struct { dst: TypedOperand, src: Operand };

pub const LoopPhi = struct {
    local: LocalId,
    phi_inputs: []PhiInput,
    dst: TypedOperand,
};

pub const ListStore = struct {
    list: TypedOperand,
    index: TypedOperand,
    src: ValueRef,
};

pub const FunctionCallee = union(enum) {
    /// a function name to call
    direct: []const u8,
    /// a value holding our function
    indirect: TypedOperand,

    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {
        return switch (self) {
            .direct => |d| .{ .direct = try alloc.dupe(u8, d) },
            .indirect => |ind| .{ .indirect = try ind.clone(alloc) },
        };
    }
};

pub const FunctionCallInst = struct {
    dst: ?TypedOperand,
    callee: FunctionCallee,
    args: []TypedOperand,
};

pub const Instruction = union(enum) {
    print: struct {
        src: TypedOperand,
    },
    len: struct {
        dst: TypedOperand,
        value: TypedOperand,
    },
    range: struct {
        dst: TypedOperand,
        start: TypedOperand,
        end: TypedOperand,
    },
    phi: struct {
        dst: TypedOperand,
        inputs: []PhiInput,
    },
    parallel_copy: struct {
        copies: []Copy,
    },
    function_param: struct {
        dst: TypedOperand,
        name: []const u8,
        index: usize,
    },
    function_call: FunctionCallInst,
    function_return: struct {
        value: ?TypedOperand,
    },
    // used to pass functions as value
    function_ref: struct {
        dst: TypedOperand,
        function_name: []const u8,
    },
    gpu_launch: struct {
        kernel: []const u8,
        args: []TypedOperand,
        work_items: TypedOperand,
    },
    // heap based variable size
    list_literal: struct {
        dst: TypedOperand,
        elements: []ValueRef,
    },
    // dst <- list[index]
    list_load: struct {
        dst: TypedOperand,
        list: TypedOperand,
        index: TypedOperand,
    },
    // list[index] <- src
    list_store: ListStore,
    // stack based fixed size array
    tuple_literal: struct {
        dst: TypedOperand,
        elements: []ValueRef,
    },
    // dst <- array[index]
    tuple_load: struct {
        dst: TypedOperand,
        tuple: TypedOperand,
        index: TypedOperand,
    },
    // dst <- lazy[index]
    lazy_load: struct {
        dst: TypedOperand,
        lazy: TypedOperand,
        index: Operand,
    },
    global_idx: struct {
        dst: TypedOperand,
    },
    // deglate to LIR impl
    lir: LirInstruction,
    unkown,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .parallel_copy => |pc| {
                for (pc.copies) |copy| {
                    copy.dst.type.deinit(alloc);
                }
                alloc.free(pc.copies);
            },
            .phi => |phi| {
                alloc.free(phi.inputs);
            },
            .function_param => |fp| {
                fp.dst.type.deinit(alloc);
                alloc.free(fp.name);
            },
            .function_ref => |fr| {
                fr.dst.type.deinit(alloc);
                alloc.free(fr.function_name);
            },
            .function_call => |fc| {
                if (fc.dst) |dst| {
                    dst.type.deinit(alloc);
                }
                switch (fc.callee) {
                    .direct => |d| alloc.free(d),
                    .indirect => |ind| ind.type.deinit(alloc),
                }
                for (fc.args) |arg| {
                    arg.type.deinit(alloc);
                }
                alloc.free(fc.args);
            },
            .tuple_literal => |tl| {
                tl.dst.type.deinit(alloc);
                alloc.free(tl.elements);
            },
            .tuple_load => |tl| {
                tl.dst.type.deinit(alloc);
                tl.tuple.type.deinit(alloc);
            },
            .list_literal => |ll| {
                ll.dst.type.deinit(alloc);
                alloc.free(ll.elements);
            },
            .lazy_load => |ll| {
                ll.lazy.type.deinit(alloc);
            },
            .range => |r| {
                r.dst.type.deinit(alloc);
            },
            .global_idx => |gl| {
                gl.dst.type.deinit(alloc);
            },
            .gpu_launch => |gl| {
                alloc.free(gl.kernel);
                alloc.free(gl.args);
            },
            .lir => |*lir| lir.deinit(alloc),
            else => {},
        }
    }

    pub fn printFn(self: @This()) !void {
        switch (self) {
            .print => |p| {
                debugPrint("print ", .{});
                p.src.operand.print();
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
                l.dst.operand.print();
                debugPrint(" <- len(", .{});
                l.value.operand.print();
                debugPrint(")\n", .{});
            },
            .phi => |p| {
                p.dst.operand.print();
                debugPrint(" <- phi (", .{});
                for (p.inputs, 0..) |phi, i| {
                    if (i != 0) debugPrint(", ", .{});
                    debugPrint("block{d}: ", .{phi.pred});
                    phi.value.operand.print();
                }
                debugPrint(")\n", .{});
            },
            .parallel_copy => |pc| {
                debugPrint("(", .{});
                for (pc.copies, 0..) |copy, i| {
                    if (i != 0) debugPrint(", ", .{});
                    copy.dst.operand.print();
                }
                debugPrint(") <- ", .{});
                debugPrint("(", .{});
                for (pc.copies, 0..) |copy, i| {
                    if (i != 0) debugPrint(", ", .{});
                    copy.src.print();
                }
                debugPrint(")\n", .{});
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
            .tuple_load => |tl| {
                tl.dst.operand.print();
                debugPrint(" <- ", .{});
                tl.tuple.operand.print();
                debugPrint("(", .{});
                tl.index.operand.print();
                debugPrint(")\n", .{});
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
            .list_load => |al| {
                al.dst.operand.print();
                debugPrint(" <- ", .{});
                al.list.operand.print();
                debugPrint("[", .{});
                al.index.operand.print();
                debugPrint("]\n", .{});
            },
            .list_store => |ls| {
                ls.list.operand.print();
                debugPrint("[", .{});
                ls.index.operand.print();
                debugPrint("] <- ", .{});
                ls.src.print();
                debugPrint("\n", .{});
            },
            .function_ref => |fr| {
                fr.dst.operand.print();
                debugPrint(" <- {s}\n", .{fr.function_name});
            },
            .function_param => |fp| {
                fp.dst.operand.print();
                debugPrint(" <- param {d}\n", .{fp.index});
            },
            .function_call => |fc| {
                if (fc.dst) |dst| {
                    dst.operand.print();
                    debugPrint(" <- ", .{});
                }
                switch (fc.callee) {
                    .direct => |function_name| debugPrint("{s}(", .{function_name}),
                    .indirect => |ind| {
                        ind.operand.print();
                        debugPrint("(", .{});
                    },
                }
                for (fc.args, 0..) |arg, i| {
                    if (i != 0) debugPrint(", ", .{});
                    arg.operand.print();
                }
                debugPrint(")\n", .{});
            },
            .function_return => |fr| {
                debugPrint("return ", .{});
                if (fr.value) |value| {
                    value.operand.print();
                }
                debugPrint("\n", .{});
            },
            .lazy_load => |ll| {
                ll.dst.operand.print();
                debugPrint("<- ", .{});
                ll.lazy.operand.print();
                debugPrint("[", .{});
                ll.index.print();
                debugPrint("]\n", .{});
            },
            // delegate to lir
            .lir => |l| try l.printFn(),
            else => |term| {
                std.debug.panic("ir instruction not impl: {s}", .{@tagName(term)});
                return error.NotImplemented;
            },
        }
    }

    pub fn replaceUses(self: *@This(), old: Operand, new: Operand) void {
        switch (self.*) {
            .range => |*r| {
                if (r.start.operand.equal(old)) r.start.operand = new;
                if (r.end.operand.equal(old)) r.end.operand = new;
            },
            .len => |*l| {
                if (l.value.operand.equal(old)) l.value.operand = new;
            },
            .tuple_load => |*tl| {
                if (tl.tuple.operand.equal(old)) tl.tuple.operand = new;
                if (tl.index.operand.equal(old)) tl.index.operand = new;
            },
            .tuple_literal => |*tl| {
                for (tl.elements) |*elem| {
                    switch (elem.*) {
                        .top => |*top| {
                            if (top.operand.equal(old)) top.*.operand = new;
                        },
                        .constant => {},
                    }
                }
            },
            .list_literal => |*ll| {
                for (ll.elements) |*elem| {
                    switch (elem.*) {
                        .top => |*top| {
                            if (top.operand.equal(old)) top.*.operand = new;
                        },
                        .constant => {},
                    }
                }
            },
            .list_load => |*ll| {
                if (ll.list.operand.equal(old)) ll.list.operand = new;
                if (ll.index.operand.equal(old)) ll.index.operand = new;
            },
            .list_store => |*ls| {
                if (ls.list.operand.equal(old)) ls.list.operand = new;
                if (ls.index.operand.equal(old)) ls.index.operand = new;
                switch (ls.src) {
                    .top => |*top| {
                        if (top.operand.equal(old)) top.operand = new;
                    },
                    .constant => {},
                }
            },
            .function_call => |*fc| {
                switch (fc.callee) {
                    .direct => {},
                    .indirect => |*dir| {
                        if (dir.operand.equal(old)) dir.operand = new;
                    },
                }
                for (fc.args) |*arg| {
                    if (arg.operand.equal(old)) arg.operand = new;
                }
            },
            // delegate to lir
            .lir => |*l| {
                l.replaceUses(old, new);
            },
            else => |e| {
                debugPrint("uses cant handle {s}\n", .{@tagName(e)});
                unreachable;
            },
        }
    }

    pub fn replaceDefines(self: *@This(), old: Operand, new: Operand) !void {
        switch (self.*) {
            .range => |*r| {
                if (r.dst.operand.equal(old)) r.dst.operand = new;
            },
            .len => |*l| {
                if (l.dst.operand.equal(old)) l.dst.operand = new;
            },
            .tuple_load => |*tl| {
                if (tl.dst.operand.equal(old)) tl.dst.operand = new;
            },
            .tuple_literal => |*tl| {
                if (tl.dst.operand.equal(old)) tl.dst.operand = new;
            },
            .list_literal => |*ll| {
                if (ll.dst.operand.equal(old)) ll.dst.operand = new;
            },
            .list_load => |*ll| {
                if (ll.dst.operand.equal(old)) ll.dst.operand = new;
            },
            .function_param => |*fp| {
                if (fp.dst.operand.equal(old)) fp.dst.operand = new;
            },
            .function_call => |*fc| {
                if (fc.dst) |*op| {
                    if (op.operand.equal(old)) {
                        op.operand = new;
                    }
                }
            },
            .lir => |*l| {
                try l.replaceDefines(old, new);
            },
            else => |e| {
                debugPrint("replaceDefines cant handle {s}\n", .{@tagName(e)});
                return error.OperandReplaceNotImpl;
            },
        }
    }

    pub fn getDefines(instruction: Instruction) ?SeenValue {
        return switch (instruction) {
            .phi => |pi| .{ .top = pi.dst },
            .range => |r| .{ .top = r.dst },
            .len => |l| .{ .top = l.dst },
            .tuple_literal => |tl| .{ .top = tl.dst },
            .tuple_load => |tl| .{ .top = tl.dst },
            .list_literal => |ll| .{ .top = ll.dst },
            .list_load => |ll| .{ .top = ll.dst },
            .list_store => null,
            .print => null,
            .function_ref => |fr| .{ .top = fr.dst },
            .function_param => |fp| .{ .top = fp.dst },
            .function_call => |fc| if (fc.dst) |op| .{ .top = op } else null,
            .function_return => null,
            .global_idx => |gi| .{ .top = gi.dst },
            .gpu_launch => null,
            .lir => |l| l.getDefines(),
            else => |e| {
                debugPrint("getDefines cant handle {s}\n", .{@tagName(e)});
                unreachable;
            },
        };
    }

    pub fn getUses(instruction: Instruction, alloc: std.mem.Allocator) !ArrayList(SeenValue) {
        var res = ArrayList(SeenValue).empty;
        errdefer res.deinit(alloc);

        switch (instruction) {
            .phi => |pi| {
                for (pi.inputs) |phi_input| {
                    try res.append(alloc, .{ .top = phi_input.value });
                }
            },
            .print => |pi| {
                try res.append(alloc, .{ .top = pi.src });
            },
            .range => |r| {
                try res.append(alloc, .{ .top = r.start });
                try res.append(alloc, .{ .top = r.end });
            },
            .len => |l| {
                try res.append(alloc, .{ .top = l.value });
            },
            .tuple_literal => |tl| {
                for (tl.elements) |elem| {
                    switch (elem) {
                        .top => |top| try res.append(alloc, .{ .top = top }),
                        .constant => {},
                    }
                }
            },
            .tuple_load => |tl| {
                try res.append(alloc, .{ .top = tl.tuple });
                try res.append(alloc, .{ .top = tl.index });
            },
            .list_literal => |ll| {
                for (ll.elements) |elem| {
                    switch (elem) {
                        .top => |top| try res.append(alloc, .{ .top = top }),
                        .constant => {},
                    }
                }
            },
            .list_load => |il| {
                try res.append(alloc, .{ .top = il.list });
                try res.append(alloc, .{ .top = il.index });
            },
            .list_store => |ls| {
                try res.append(alloc, .{ .top = ls.list });
                try res.append(alloc, .{ .top = ls.index });
                switch (ls.src) {
                    .top => |top| {
                        try res.append(alloc, .{ .top = top });
                    },
                    .constant => {},
                }
            },
            .function_ref => {},
            .function_param => {},
            .function_call => |fc| {
                if (fc.dst) |dst| {
                    dst.type.deinit(alloc);
                }
                switch (fc.callee) {
                    .direct => {},
                    .indirect => |ind| {
                        try res.append(alloc, .{ .top = ind });
                    },
                }
                for (fc.args) |arg| {
                    try res.append(alloc, .{ .top = arg });
                }
            },
            .function_return => |fc| {
                if (fc.value) |top| {
                    try res.append(alloc, .{ .top = top });
                }
            },
            .global_idx => {},
            .gpu_launch => |gl| {
                // no need to append arg.work_items since its contained in args already
                for (gl.args) |arg| {
                    try res.append(alloc, .{ .top = arg });
                }
            },
            .lir => |l| {
                var seen = try l.getUses(alloc);
                defer seen.deinit(alloc);
                for (seen.items) |s| {
                    try res.append(alloc, s);
                }
            },
            else => |e| {
                debugPrint("getUses cant handle {s}\n", .{@tagName(e)});
                unreachable;
            },
        }
        return res;
    }
};
