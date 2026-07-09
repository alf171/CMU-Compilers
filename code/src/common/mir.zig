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

pub const PhiInput = struct { pred: BlockId, value: Operand };

pub const Copy = struct { dst: TypedOperand, src: Operand };

pub const LoopPhi = struct {
    local: LocalId,
    phi_inputs: []PhiInput,
    dst: TypedOperand,
};

pub const Instruction = union(enum) {
    print: struct {
        src: TypedOperand,
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
    function_call: struct {
        dst: ?TypedOperand,
        callee: union(enum) {
            /// a function name to call
            direct: []const u8,
            /// a value holding our function
            indirect: TypedOperand,
        },
        args: []TypedOperand,
    },
    function_return: struct {
        value: ?Operand,
    },
    // used to pass functions as value
    function_ref: struct {
        dst: TypedOperand,
        function_name: []const u8,
    },
    // heap based variable size
    list_literal: struct {
        dst: TypedOperand,
        elements: []ValueRef,
    },
    // dst <- lazy[index]
    lazy_load: struct {
        dst: Operand,
        lazy: TypedOperand,
        index: Operand,
    },
    cast: struct {
        dst: Operand,
        dst_target_type: TypeInfo,
        src: TypedOperand,
    },
    // deglate to LIR impl
    lir: LirInstruction,
    unkown,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
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
                alloc.free(fc.args);
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
                l.dst.print();
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
                    phi.value.print();
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
            .list_literal => |al| {
                al.dst.operand.print();
                debugPrint(" <- [", .{});
                for (al.elements, 0..) |elem, i| {
                    if (i != 0) debugPrint(", ", .{});
                    elem.print();
                }
                debugPrint("]\n", .{});
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
                    value.print();
                }
                debugPrint("\n", .{});
            },
            .lazy_load => |ll| {
                ll.dst.print();
                debugPrint("<- ", .{});
                ll.lazy.operand.print();
                debugPrint("[", .{});
                ll.index.print();
                debugPrint("]\n", .{});
            },
            .cast => |c| {
                c.dst.print();
                debugPrint(" <- ({s})", .{@tagName(c.dst_target_type)});
                c.src.operand.print();
                debugPrint("\n", .{});
            },
            // delegate to lir
            .lir => |l| try l.printFn(),
            else => |term| {
                std.debug.panic("ir instruction not impl: {s}", .{@tagName(term)});
                return error.NotImplemented;
            },
        }
    }

    pub fn replaceUses(self: *@This(), old: Operand, new: Operand) !void {
        switch (self.*) {
            .range => |*r| {
                if (r.start.operand.equal(old)) r.start.operand = new;
                if (r.end.operand.equal(old)) r.end.operand = new;
            },
            .len => |*l| {
                if (l.value.operand.equal(old)) l.value.operand = new;
            },
            .list_literal => |*ll| {
                for (ll.elements) |*elem| {
                    switch (elem.*) {
                        .operand => |*op| {
                            if (op.operand.equal(old)) op.*.operand = new;
                        },
                        .constant => {},
                    }
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
                try l.replaceUses(old, new);
            },
            else => |e| {
                debugPrint("uses cant handle {s}\n", .{@tagName(e)});
                return error.OperandReplaceNotImpl;
            },
        }
    }

    pub fn replaceDefines(self: *@This(), old: Operand, new: Operand) !void {
        switch (self.*) {
            .range => |*r| {
                if (r.dst.operand.equal(old)) r.dst.operand = new;
            },
            .len => |*l| {
                if (l.dst.equal(old)) l.dst = new;
            },
            .list_literal => |*ll| {
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

    pub fn getDefines(instruction: Instruction) !?SeenValue {
        return switch (instruction) {
            .phi => |pi| .{ .operand = pi.dst.operand },
            .range => |r| .{ .operand = r.dst.operand },
            .len => |l| .{ .operand = l.dst },
            .list_literal => |ll| .{ .operand = ll.dst.operand },
            .print => null,
            .function_ref => |fr| .{ .operand = fr.dst.operand },
            .function_param => |fp| .{ .operand = fp.dst.operand },
            .function_call => |fc| if (fc.dst) |op| .{ .operand = op.operand } else null,
            .function_return => null,
            .cast => |c| .{ .operand = c.dst },
            .lir => |l| try l.getDefines(),
            else => |e| {
                debugPrint("getDefines cant handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        };
    }

    pub fn getUses(instruction: Instruction, alloc: std.mem.Allocator) !ArrayList(SeenValue) {
        var res = ArrayList(SeenValue).empty;
        errdefer res.deinit(alloc);

        switch (instruction) {
            .phi => |pi| {
                for (pi.inputs) |phi_input| {
                    try res.append(alloc, .{ .operand = phi_input.value });
                }
            },
            .print => |pi| {
                try res.append(alloc, .{ .operand = pi.src.operand });
            },
            .range => |r| {
                try res.append(alloc, .{ .operand = r.start.operand });
                try res.append(alloc, .{ .operand = r.end.operand });
            },
            .len => |l| {
                try res.append(alloc, .{ .operand = l.value.operand });
            },
            .list_literal => |ll| {
                for (ll.elements) |elem| {
                    switch (elem) {
                        .operand => |op| try res.append(alloc, .{ .operand = op.operand }),
                        .constant => {},
                    }
                }
            },
            .function_ref => {},
            .function_param => {},
            .function_call => |fc| {
                switch (fc.callee) {
                    .direct => {},
                    .indirect => |ind| {
                        try res.append(alloc, .{ .operand = ind.operand });
                    },
                }
                for (fc.args) |arg| {
                    try res.append(alloc, .{ .operand = arg.operand });
                }
            },
            .function_return => |fc| {
                if (fc.value) |op| {
                    try res.append(alloc, .{ .operand = op });
                }
            },
            .cast => |c| {
                try res.append(alloc, .{ .operand = c.src.operand });
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
                return error.NotImpl;
            },
        }
        return res;
    }
};
