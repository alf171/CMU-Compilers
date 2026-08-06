const std = @import("std");
const ArrayList = @import("std").ArrayList;
const debugPrint = std.debug.print;
const LocalInfo = @import("ir.zig").LocalInfo;
const Operand = @import("alloc.zig").Operand;
const ConstValue = @import("ir.zig").ConstValue;
const BinOp = @import("ir.zig").BinOp;
const BlockId = @import("ir.zig").BlockId;
const ClassId = @import("ir.zig").ClassId;
const LocalId = @import("ir.zig").LocalId;
const CmpOp = @import("ir.zig").CmpOp;
const UnaryOp = @import("ir.zig").UnaryOp;
const SeenValue = @import("ir.zig").SeenValue;
const SeenValuePtr = @import("ir.zig").SeenValuePtr;
const ValueRef = @import("ir.zig").ValueRef;
const TypedOperand = @import("alloc.zig").TypedOperand;
const TypeInfo = @import("types.zig").TypeInfo;
const TypeBindings = @import("types.zig").TypeBindings;
const LirInstruction = @import("lir.zig").Instruction;

pub const PhiInput = struct {
    pred: BlockId,
    value: TypedOperand,

    pub fn clone(self: *@This(), alloc: std.mem.Allocator) !@This() {
        return .{
            .pred = self.pred,
            .value = try self.value.clone(alloc),
        };
    }
};

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
        end: ?TypedOperand,
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
        index: TypedOperand,
    },
    class_init: struct {
        dst: TypedOperand,
        class_id: ClassId,
        args: []TypedOperand,
    },
    // instance <- *(src + offset)
    field_store: struct {
        instance: TypedOperand,
        offset: usize,
        src: TypedOperand,
    },
    // dst <- *(instance + offset)
    field_load: struct {
        dst: TypedOperand,
        instance: TypedOperand,
        offset: usize,
    },
    /// gpu method
    gpu_launch: struct {
        kernel: []const u8,
        args: []TypedOperand,
        work_items: TypedOperand,
    },
    /// gpu method
    global_idx: struct {
        dst: TypedOperand,
        // x=0, y=1, z=2
        axis: ValueRef,
    },
    // dst <- [lst] * count
    list_repeat: struct {
        dst: TypedOperand,
        list: TypedOperand,
        count: TypedOperand,
    },
    // deglate to LIR impl
    lir: LirInstruction,
    unkown,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .parallel_copy => |pc| {
                for (pc.copies) |copy| {
                    copy.dst.deinit(alloc);
                }
                alloc.free(pc.copies);
            },
            .phi => |phi| {
                phi.dst.deinit(alloc);
                for (phi.inputs) |input| {
                    input.value.deinit(alloc);
                }
                alloc.free(phi.inputs);
            },
            .function_param => |fp| {
                fp.dst.deinit(alloc);
                alloc.free(fp.name);
            },
            .function_ref => |fr| {
                fr.dst.type.deinit(alloc);
                alloc.free(fr.function_name);
            },
            .function_call => |fc| {
                if (fc.dst) |dst| {
                    dst.deinit(alloc);
                }
                switch (fc.callee) {
                    .direct => |d| alloc.free(d),
                    .indirect => |ind| ind.deinit(alloc),
                }
                for (fc.args) |arg| {
                    arg.deinit(alloc);
                }
                alloc.free(fc.args);
            },
            .tuple_literal => |tl| {
                tl.dst.deinit(alloc);
                alloc.free(tl.elements);
            },
            .tuple_load => |tl| {
                tl.dst.deinit(alloc);
                tl.tuple.deinit(alloc);
            },
            .list_load => |ll| {
                ll.dst.deinit(alloc);
                ll.list.deinit(alloc);
                ll.index.deinit(alloc);
            },
            .list_literal => |ll| {
                ll.dst.deinit(alloc);
                alloc.free(ll.elements);
            },
            .list_store => |ls| {
                ls.list.deinit(alloc);
                ls.index.deinit(alloc);
                switch (ls.src) {
                    .top => |top| {
                        top.deinit(alloc);
                    },
                    .constant => {},
                }
            },
            .lazy_load => |ll| {
                ll.dst.deinit(alloc);
                ll.lazy.deinit(alloc);
                ll.index.deinit(alloc);
            },
            .range => |r| {
                r.dst.deinit(alloc);
            },
            .global_idx => |gl| {
                gl.dst.deinit(alloc);
            },
            .gpu_launch => |gl| {
                alloc.free(gl.kernel);
                for (gl.args) |arg| {
                    arg.deinit(alloc);
                }
                alloc.free(gl.args);
                gl.work_items.deinit(alloc);
            },
            .class_init => |ci| {
                for (ci.args) |arg| {
                    arg.deinit(alloc);
                }
                alloc.free(ci.args);
                ci.dst.deinit(alloc);
            },
            .field_load => |fl| {
                fl.dst.deinit(alloc);
                fl.instance.deinit(alloc);
            },
            .field_store => |fs| {
                fs.instance.deinit(alloc);
                fs.src.deinit(alloc);
            },
            .list_repeat => |lr| {
                lr.dst.deinit(alloc);
                lr.list.deinit(alloc);
                lr.count.deinit(alloc);
            },
            .len => |l| {
                l.dst.deinit(alloc);
                l.value.deinit(alloc);
            },
            .print => |p| {
                p.src.deinit(alloc);
                if (p.end) |*end| end.deinit(alloc);
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
                ll.index.operand.print();
                debugPrint("]\n", .{});
            },
            .gpu_launch => |gl| {
                debugPrint("{s}(", .{gl.kernel});
                for (gl.args) |arg| {
                    arg.operand.print();
                    debugPrint(", ", .{});
                }
                gl.work_items.operand.print();
                debugPrint(")\n", .{});
            },
            .global_idx => |gi| {
                gi.dst.operand.print();
                debugPrint(" <- global_id(", .{});
                gi.axis.print();
                debugPrint(")\n", .{});
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
            .global_idx => |*gi| {
                switch (gi.axis) {
                    .top => |*top| {
                        if (top.operand.equal(old)) {
                            top.operand = new;
                        }
                    },
                    else => {},
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
        var addressable_instruction = instruction;
        const define = addressable_instruction.getDefinePtrs() orelse {
            return null;
        };
        return define.value();
    }

    pub fn getDefinePtrs(instruction: *Instruction) ?SeenValuePtr {
        return switch (instruction.*) {
            .phi => |*pi| .{ .top = &pi.dst },
            .range => |*r| .{ .top = &r.dst },
            .len => |*l| .{ .top = &l.dst },
            .tuple_literal => |*tl| .{ .top = &tl.dst },
            .tuple_load => |*tl| .{ .top = &tl.dst },
            .list_literal => |*ll| .{ .top = &ll.dst },
            .list_load => |*ll| .{ .top = &ll.dst },
            .list_store => null,
            .print => null,
            .function_ref => |*fr| .{ .top = &fr.dst },
            .function_param => |*fp| .{ .top = &fp.dst },
            .function_call => |*fc| if (fc.dst) |*op| .{ .top = op } else null,
            .function_return => null,
            .global_idx => |*gi| .{ .top = &gi.dst },
            .gpu_launch => null,
            .lazy_load => |*ll| .{ .top = &ll.dst },
            .list_repeat => |*lr| .{ .top = &lr.dst },
            .field_store => null,
            .field_load => |*fl| .{ .top = &fl.dst },
            .class_init => |*ci| .{ .top = &ci.dst },
            .lir => |*l| return l.getDefinePtrs(),
            else => |e| {
                debugPrint("getDefines cant handle {s}\n", .{@tagName(e)});
                unreachable;
            },
        };
    }

    pub fn getUses(instruction: Instruction, alloc: std.mem.Allocator) !ArrayList(SeenValue) {
        var addressable_instruction = instruction;
        var uses = try addressable_instruction.getUsePtrs(alloc);
        defer uses.deinit(alloc);

        var result: ArrayList(SeenValue) = .empty;
        errdefer result.deinit(alloc);

        for (uses.items) |use| {
            try result.append(alloc, use.value());
        }
        return result;
    }

    pub fn getUsePtrs(instruction: *Instruction, alloc: std.mem.Allocator) !ArrayList(SeenValuePtr) {
        var res: ArrayList(SeenValuePtr) = .empty;
        errdefer res.deinit(alloc);

        switch (instruction.*) {
            .phi => |*pi| {
                for (pi.inputs) |*phi_input| {
                    try res.append(alloc, .{ .top = &phi_input.value });
                }
            },
            .print => |*pi| {
                try res.append(alloc, .{ .top = &pi.src });
            },
            .range => |*r| {
                try res.append(alloc, .{ .top = &r.start });
                try res.append(alloc, .{ .top = &r.end });
            },
            .len => |*l| {
                try res.append(alloc, .{ .top = &l.value });
            },
            .tuple_literal => |*tl| {
                for (tl.elements) |*elem| {
                    switch (elem.*) {
                        .top => |*top| try res.append(alloc, .{ .top = top }),
                        .constant => {},
                    }
                }
            },
            .tuple_load => |*tl| {
                try res.append(alloc, .{ .top = &tl.tuple });
                try res.append(alloc, .{ .top = &tl.index });
            },
            .list_literal => |*ll| {
                for (ll.elements) |*elem| {
                    switch (elem.*) {
                        .top => |*top| try res.append(alloc, .{ .top = top }),
                        .constant => {},
                    }
                }
            },
            .list_load => |*il| {
                try res.append(alloc, .{ .top = &il.list });
                try res.append(alloc, .{ .top = &il.index });
            },
            .list_store => |*ls| {
                try res.append(alloc, .{ .top = &ls.list });
                try res.append(alloc, .{ .top = &ls.index });
                switch (ls.src) {
                    .top => |*top| {
                        try res.append(alloc, .{ .top = top });
                    },
                    .constant => {},
                }
            },
            .function_ref => {},
            .function_param => {},
            .function_call => |*fc| {
                switch (fc.callee) {
                    .direct => {},
                    .indirect => |*ind| {
                        try res.append(alloc, .{ .top = ind });
                    },
                }
                for (fc.args) |*arg| {
                    try res.append(alloc, .{ .top = arg });
                }
            },
            .function_return => |*fc| {
                if (fc.value) |*top| {
                    try res.append(alloc, .{ .top = top });
                }
            },
            .global_idx => |*gi| {
                switch (gi.axis) {
                    .top => |*top| {
                        try res.append(alloc, .{ .top = top });
                    },
                    else => {},
                }
            },
            .gpu_launch => |*gl| {
                // no need to append arg.work_items since its contained in args already
                for (gl.args) |*arg| {
                    try res.append(alloc, .{ .top = arg });
                }
            },
            .lazy_load => |*ll| {
                try res.append(alloc, .{ .top = &ll.lazy });
                try res.append(alloc, .{ .top = &ll.index });
            },
            .lir => |*l| {
                var seen = try l.getUsePtrs(alloc);
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

    pub fn clone(self: *@This(), alloc: std.mem.Allocator) !@This() {
        return switch (self.*) {
            .function_param => |fp| .{ .function_param = .{
                .dst = try fp.dst.clone(alloc),
                .name = try alloc.dupe(u8, fp.name),
                .index = fp.index,
            } },
            .print => |p| .{ .print = .{
                .src = try p.src.clone(alloc),
                .end = if (p.end) |end| try end.clone(alloc) else null,
            } },
            .list_load => |ll| .{ .list_load = .{
                .dst = try ll.dst.clone(alloc),
                .list = try ll.list.clone(alloc),
                .index = try ll.index.clone(alloc),
            } },
            .len => |l| .{ .len = .{
                .dst = try l.dst.clone(alloc),
                .value = try l.value.clone(alloc),
            } },
            .function_return => |fr| .{ .function_return = .{
                .value = if (fr.value) |value| try value.clone(alloc) else null,
            } },
            .range => |r| .{ .range = .{
                .dst = try r.dst.clone(alloc),
                .start = try r.start.clone(alloc),
                .end = try r.end.clone(alloc),
            } },
            .phi => |p| blk: {
                var phi_inputs = try alloc.alloc(PhiInput, p.inputs.len);
                for (p.inputs, 0..) |*input, i| {
                    phi_inputs[i] = try input.clone(alloc);
                }
                break :blk .{
                    .phi = .{
                        .dst = try p.dst.clone(alloc),
                        .inputs = phi_inputs,
                    },
                };
            },
            .lazy_load => |ll| .{
                .lazy_load = .{
                    .dst = try ll.dst.clone(alloc),
                    .lazy = try ll.lazy.clone(alloc),
                    .index = ll.index,
                },
            },
            .list_store => |ls| .{
                .list_store = .{
                    .list = try ls.list.clone(alloc),
                    .index = try ls.index.clone(alloc),
                    .src = try ls.src.clone(alloc),
                },
            },
            .lir => |*lir| .{
                .lir = try lir.clone(alloc),
            },
            else => |e| {
                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        };
    }

    pub fn remapInstruction(
        instruction: *@This(),
        new_function_id: usize,
        bindings: *TypeBindings,
        alloc: std.mem.Allocator,
    ) !void {
        if (instruction.getDefinePtrs()) |define| {
            switch (define) {
                .top => |top| {
                    top.operand = top.operand.withFunctionId(new_function_id);
                    const concrete_type = try top.type.substitute(bindings, alloc);
                    top.type.deinit(alloc);
                    top.type = concrete_type;
                },
                .local => {},
            }
        }

        var uses = try instruction.getUsePtrs(alloc);
        defer uses.deinit(alloc);
        for (uses.items) |use| {
            switch (use) {
                .top => |top| {
                    top.operand = top.operand.withFunctionId(new_function_id);
                    const concrete_type = try top.type.substitute(bindings, alloc);
                    top.type.deinit(alloc);
                    top.type = concrete_type;
                },
                .local => {},
            }
        }
    }
};
