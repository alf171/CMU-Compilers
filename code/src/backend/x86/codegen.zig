const std = @import("std");
const ArrayList = std.ArrayList;

const common = @import("common");
const Program = common.program.Program;
const TypeInfo = common.types.TypeInfo;
const Block = common.ir.BasicBlock;
const ConstValue = common.ir.ConstValue;
const Function = common.ir.Function;
const ValueRef = common.ir.ValueRef;
const getElementType = common.types.getElementType;
const ColoredGraph = @import("middle").color.ColoredGraph;
const Abi = @import("../abi.zig").Abi;
const valueAsImm = @import("../common.zig").valueAsImm;
const ScratchReg = @import("reg.zig").scratch_reg;
const ScratchReg2 = @import("reg.zig").scratch_reg_2;

pub fn emit(program: *const Program, colors: *const ColoredGraph, abi: Abi, alloc: std.mem.Allocator) ![]u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try createProgramHeader(&out, alloc);
    try emitFunction(&out, colors, &program.main, abi, true, alloc);
    for (program.functions.items) |function| {
        try emitFunction(&out, colors, &function, abi, false, alloc);
    }

    try createFooter(&out, alloc);

    return out.toOwnedSlice(alloc);
}

fn emitFunction(
    out: *ArrayList(u8),
    colors: *const ColoredGraph,
    function: *const Function,
    abi: Abi,
    is_main: bool,
    alloc: std.mem.Allocator,
) !void {
    const local_count = countLocals(&function.blocks);
    const array_slot_count = countArraySlots(&function.blocks);
    const local_stack_size = std.mem.alignForward(
        usize,
        (array_slot_count + local_count) * 8,
        16,
    );
    const frame_stack_size = std.mem.alignForward(
        usize,
        local_stack_size + (function.next_mem * 8),
        16,
    );
    try createFunctionHeader(out, function.name, frame_stack_size, abi, alloc);
    var next_array_location: usize = 0;
    for (function.blocks.items) |block| {
        try out.print(alloc, "{s}_L{d}:\n", .{ function.name, block.id });
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .function_call => |fc| {
                    switch (fc.callee) {
                        .direct => |function_name| {
                            try out.print(alloc, "\tcallq {s}\n", .{function_name});
                        },
                        else => return error.NotImpl,
                    }
                },
                .len => |l| {
                    const dst = try abi.regFor(l.dst.operand, colors, .gp);
                    const src = try abi.regFor(l.value.operand, colors, .gp);
                    switch (l.value.type) {
                        .list => {
                            try out.print(alloc, "\tmovq (%{s}), %{s}\n", .{ src, dst });
                        },
                        else => |e| {
                            std.debug.print("len called on {s} unexpectedly\n", .{@tagName(e)});
                            return error.InvalidLenCall;
                        },
                    }
                },
                .lir => |l| {
                    switch (l) {
                        .constant => |c| {
                            const dst = try abi.regFor(c.dst, colors, .gp);
                            switch (c.value) {
                                .i64 => |i| {
                                    try out.print(alloc, "\tmovq ${d}, %{s}\n", .{ i, dst });
                                },
                                else => |e| {
                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                    return error.NotImpl;
                                },
                            }
                        },
                        .move => |m| {
                            switch (m.dst.operand) {
                                .temp => {
                                    switch (m.src) {
                                        .temp => {
                                            const dst = try abi.regFor(m.dst.operand, colors, .gp);
                                            const src = try abi.regFor(m.src, colors, .gp);
                                            try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ src, dst });
                                        },
                                        .reg => |reg| {
                                            const dst = try abi.regFor(m.dst.operand, colors, .gp);
                                            const src = try abi.regForFromIndex(reg.id, .gp);
                                            try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ src, dst });
                                        },
                                        else => |e| {
                                            std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                            return error.NotImpl;
                                        },
                                    }
                                },
                                .reg => |reg| {
                                    switch (m.src) {
                                        .temp => {
                                            const dst = try abi.regForFromIndex(reg.id, .gp);
                                            const src = try abi.regFor(m.src, colors, .gp);
                                            try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ src, dst });
                                        },
                                        else => |e| {
                                            std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                            return error.NotImpl;
                                        },
                                    }
                                },
                                else => |e| {
                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                    return error.NotImpl;
                                },
                            }
                        },
                        .binop => |bop| {
                            const dst = try abi.regFor(bop.dst.operand, colors, .gp);
                            const lhs = try valueToReg(bop.lhs, out, ScratchReg, colors, abi, alloc);
                            if (!std.mem.eql(u8, dst, lhs)) {
                                try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ lhs, dst });
                            }

                            const rhs = if (valueAsImm(bop.rhs)) |imm| try std.fmt.allocPrint(alloc, "${d}", .{imm}) else blk: {
                                const reg = try abi.regFor(bop.rhs.operand.operand, colors, .gp);
                                break :blk try std.fmt.allocPrint(alloc, "%{s}", .{reg});
                            };
                            switch (bop.op) {
                                .add => {
                                    try out.print(alloc, "\taddq {s}, %{s}\n", .{ rhs, dst });
                                },
                                .div => {
                                    // FIXME: this is wrong
                                    try out.print(alloc, "\tmovq $0, %{s}\n", .{dst});
                                },
                                .mod => {
                                    // FIXME: this is wrong
                                    try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ lhs, dst });
                                },
                                else => |e| {
                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                    return error.NotImpl;
                                },
                            }
                        },
                        .compare => |c| {
                            const dst = try abi.regFor(c.dst.operand, colors, .gp);
                            const lhs = try abi.regFor(c.lhs.operand, colors, .gp);
                            const rhs = try abi.regFor(c.rhs.operand, colors, .gp);
                            try out.print(alloc, "\tcmpq %{s}, %{s}\n", .{ lhs, rhs });
                            // HACK: use lower 8 bits of %rax
                            try out.print(alloc, "\t{s} %al\n", .{condForCmp(c.op)});
                            try out.print(alloc, "\tmovzbq %al, %{s}\n", .{dst});
                        },
                        .jump => |j| {
                            try out.print(alloc, "\tjmp {s}_L{d}\n", .{ function.name, j.target });
                        },
                        .branch => |b| {
                            const cond = try abi.regFor(b.condition, colors, .gp);
                            try out.print(alloc, "\tcmpq $0, %{s}\n", .{cond});
                            try out.print(alloc, "\tjne {s}_L{d}\n", .{ function.name, b.then_block });
                            try out.print(alloc, "\tjmp {s}_L{d}\n", .{ function.name, b.else_block });
                        },
                        .tuple_literal => |tl| {
                            const dst = try abi.regFor(tl.dst.operand, colors, .gp);

                            const tuple_type = switch (tl.dst.type) {
                                .tuple => |tuple| tuple.elements,
                                else => return error.WrongType,
                            };

                            // get our overall size
                            var tuple_size: usize = 0;
                            for (tuple_type) |cur_type| {
                                tuple_size += try cur_type.sizeOfType();
                            }
                            const tuple_slots = std.mem.alignForward(usize, tuple_size, 8) / 8;
                            const base_slot = next_array_location;
                            next_array_location += tuple_slots;

                            // array[i] = sp - end + adjust(i)
                            const base_offset = arrayOffset(local_count, base_slot + tuple_slots - 1);
                            var cur_offset: usize = 0;
                            for (tl.elements, 0..) |elem, i| {
                                const src = switch (elem) {
                                    .operand => try abi.regFor(elem.operand.operand, colors, .gp),
                                    .constant => |c| blk: {
                                        try emitConstantToReg(out, ScratchReg, c, alloc);
                                        break :blk ScratchReg;
                                    },
                                };

                                const offset = base_offset - cur_offset;

                                const elem_type = switch (tl.dst.type) {
                                    .tuple => |tuple| tuple.elements[i],
                                    else => return error.WrongType,
                                };

                                switch (elem_type) {
                                    .int => try emitStackStore(out, src, offset, ScratchReg2, alloc),
                                    .bool, .char => try emitStackStoreByte(out, src, offset, ScratchReg2, alloc),
                                    else => return error.NotImpl,
                                }
                                cur_offset += try elem_type.sizeOfType();
                            }
                            // array_base = x29 - end
                            try out.print(alloc, "\tleaq -{d}(%rbp), %{s}\n", .{ base_offset, dst });
                        },
                        .list_len_set => |lls| {
                            const src = try abi.regFor(lls.list.operand, colors, .gp);
                            const len = try abi.regFor(lls.len, colors, .gp);
                            try out.print(alloc, "\tmovq %{s}, (%{s})\n", .{ len, src });
                        },
                        .list_store => |ls| {
                            const elem_type = try getElementType(ls.list.type);
                            switch (elem_type) {
                                // index = (index + 1) << 3
                                .list, .tuple => {
                                    const dst = try abi.regFor(ls.list.operand, colors, .gp);
                                    std.debug.assert(ls.src == .operand);
                                    const src = try abi.regFor(ls.src.operand.operand, colors, .gp);
                                    const index = try abi.regFor(ls.index, colors, .gp);
                                    try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ ScratchReg, index });
                                    try out.print(alloc, "\tshlq $3, %{s}\n", .{ScratchReg});
                                    try out.print(alloc, "\taddq $8, %{s}\n", .{ScratchReg});
                                    try out.print(alloc, "\tmovq %{s}, (%{s}, %{s})\n", .{ src, dst, ScratchReg });
                                },
                                .char => {
                                    const dst = try abi.regFor(ls.list.operand, colors, .gp);
                                    const index = try abi.regFor(ls.index, colors, .gp);
                                    switch (ls.src) {
                                        .constant => |constant| {
                                            switch (constant) {
                                                .char => |c| {
                                                    try out.print(alloc, "\tmovq ${d}, 8(%{s},%{s},8)\n", .{ c, dst, index });
                                                },
                                                else => return error.NotImpl,
                                            }
                                        },
                                        .operand => |o| {
                                            const src = try abi.regFor(o.operand, colors, .gp);
                                            try out.print(alloc, "\tmovq %{s}, 8(%{s},%{s},8)\n", .{ src, dst, index });
                                        },
                                    }
                                },
                                else => |e| {
                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                    return error.UnexpectedType;
                                },
                            }
                        },
                        .select => |s| {
                            const dst = try abi.regFor(s.dst, colors, .gp);
                            const if_reg = try valueToReg(s.if_value, out, ScratchReg, colors, abi, alloc);
                            const else_reg = try valueToReg(s.else_value, out, ScratchReg2, colors, abi, alloc);

                            const condition = try abi.regFor(s.condition, colors, .gp);

                            try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ else_reg, dst });
                            try out.print(alloc, "\tcmpq $0, %{s}\n", .{condition});
                            try out.print(alloc, "\tcmovne %{s}, %{s}\n", .{ if_reg, dst });
                        },
                        else => |e| {
                            std.debug.panic("ir instruction doesnt have a mapping in arm backend: {s}\n", .{@tagName(e)});
                            return error.NotSupported;
                        },
                    }
                },
                else => |ir| {
                    std.debug.panic("ir instruction doesnt have a mapping in arm backend: {s}\n", .{@tagName(ir)});
                    return error.NotSupported;
                },
            }
        }
        if (block.successors.items.len == 0) {
            try out.print(alloc, "\tjmp {s}_epilogue\n", .{function.name});
        }
    }
    try createFunctionFooter(out, function.name, frame_stack_size, is_main, abi, alloc);
}

fn createProgramHeader(out: *ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, ".text\n");
    try out.appendSlice(alloc, ".global main\n");
}

fn createFunctionHeader(out: *ArrayList(u8), name: []const u8, local_stack_size: usize, abi: Abi, alloc: std.mem.Allocator) !void {
    try out.print(alloc, "{s}:\n", .{name});
    try out.appendSlice(alloc, "\tpushq %rbp\n");
    try out.appendSlice(alloc, "\tmovq %rsp, %rbp\n");
    if (local_stack_size > 0) {
        try out.print(alloc, "\tsubq ${d}, %rsp\n", .{local_stack_size});
    }
    try saveCalleeSaveReg(out, abi, alloc);
}

fn saveCalleeSaveReg(out: *ArrayList(u8), abi: Abi, alloc: std.mem.Allocator) !void {
    for (abi.gp_callee_save_regs) |reg| {
        try out.print(alloc, "\tpushq %{s}\n", .{reg});
    }
}

fn restoreCalleeSafeReg(out: *ArrayList(u8), abi: Abi, alloc: std.mem.Allocator) !void {
    var i = abi.gp_callee_save_regs.len;
    while (i > 0) {
        i -= 1;
        const reg = abi.gp_callee_save_regs[i];
        try out.print(alloc, "\tpopq %{s}\n", .{reg});
    }
}

fn emitStackLoad(
    out: *ArrayList(u8),
    dst: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    _ = scratch;
    try out.print(alloc, "\tmovzbq -{d}(%rbp), %{s}\n", .{ offset, dst });
}

fn emitStackLoadByte(
    out: *ArrayList(u8),
    dst: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    _ = scratch;
    try out.print(alloc, "\tmovq -{d}(%rbp), %{s}\n", .{ offset, dst });
}

fn emitStackStore(
    out: *ArrayList(u8),
    src: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    _ = scratch;
    try out.print(alloc, "\tmovq %{s}, -{d}(%rbp)\n", .{ src, offset });
}

fn emitStackStoreByte(
    out: *ArrayList(u8),
    src: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    _ = scratch;
    // TODO: use movb?
    try out.print(alloc, "\tmovq %{s}, -{d}(%rbp)\n", .{ src, offset });
}

fn createFunctionFooter(out: *ArrayList(u8), name: []const u8, local_stack_size: usize, is_main: bool, abi: Abi, alloc: std.mem.Allocator) !void {
    try out.print(alloc, "{s}_epilogue:\n", .{name});
    if (is_main) {
        try out.appendSlice(alloc, "\tcallq arena_free\n");
        try out.appendSlice(alloc, "\tmovq $0, %rax\n");
    }

    try restoreCalleeSafeReg(out, abi, alloc);
    if (local_stack_size > 0) {
        try out.print(alloc, "\taddq ${d}, %rsp\n", .{local_stack_size});
    }

    // restore frame pointer and return address
    try out.appendSlice(alloc, "\tpopq %rbp\n");
    try out.appendSlice(alloc, "\tretq\n");
}

fn createFooter(out: *ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, "\n.text\n");
    try out.appendSlice(alloc, "fmt:\n");
    try out.appendSlice(alloc, "\t.asciz \"%ld\\n\"\n");
}

fn countLocals(blocks: *const ArrayList(Block)) usize {
    var max_local: ?common.ir.LocalId = null;
    for (blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .lir => |l| {
                    switch (l) {
                        .store_local => |sl| {
                            max_local = if (max_local) |m| @max(m, sl.local.id) else sl.local.id;
                        },
                        .load_local => |ll| {
                            max_local = if (max_local) |m| @max(m, ll.local.id) else ll.local.id;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
    return if (max_local) |m| @as(usize, m) + 1 else 0;
}

fn countArraySlots(blocks: *const ArrayList(Block)) usize {
    var slots: usize = 0;
    for (blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .lir => |l| {
                    switch (l) {
                        .tuple_literal => |al| slots += al.elements.len,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
    return slots;
}

fn localOffset(local: common.ir.LocalId) usize {
    return (@as(usize, local) + 1) * 8;
}

fn arrayOffset(local_count: usize, array_slot_index: usize) usize {
    return (local_count + array_slot_index + 1) * 8;
}

fn spillOffset(local_stack_size: usize, slot: usize) usize {
    return local_stack_size + (slot + 1) * 8;
}

fn emitConstantToReg(
    out: *ArrayList(u8),
    dst: []const u8,
    value: ConstValue,
    alloc: std.mem.Allocator,
) !void {
    switch (value) {
        .i64, .i32 => |i| try emitMov(out, dst, i, alloc),
        .char => |c| try out.print(alloc, "\tmov {s}, #{d}\n", .{ dst, c }),
        .bool => |b| try out.print(alloc, "\tmov {s}, #{d}\n", .{ dst, @intFromBool(b) }),
        .float => return error.NotImpl,
    }
}

fn emitMov(out: *ArrayList(u8), dst: []const u8, value: i64, alloc: std.mem.Allocator) !void {
    if (value < 0) {
        const positive: u64 = @intCast(-value);
        try emitMovUnsigned(out, dst, positive, alloc);
        try out.print(alloc, "\tneg {s}, {s}\n", .{ dst, dst });
        return;
    }
    try emitMovUnsigned(out, dst, @intCast(value), alloc);
}

fn emitMovUnsigned(out: *ArrayList(u8), dst: []const u8, value: u64, alloc: std.mem.Allocator) !void {
    // [0..] [0..] [0..] [<lower>]
    const lower: u16 = @truncate(value);
    // also zeros out other portions
    try out.print(alloc, "\tmovz {s}, #{d}\n", .{ dst, lower });
    // [<64>] [<32>] [<16>] [<done>]
    inline for (.{ 16, 32, 48 }) |shift| {
        const shifted_value: u16 = @truncate(value >> shift);
        if (shifted_value != 0) {
            try out.print(alloc, "\tmovk {s}, {d}, lsl #{d}\n", .{ dst, shifted_value, shift });
        }
    }
}

fn condForCmp(op: common.ir.CmpOp) []const u8 {
    return switch (op) {
        .eq => "sete",
        .neq => "setne",
        .lt => "setl",
        .lte => "stle",
        .gt => "setg",
        .gte => "setge",
    };
}

pub fn valueToReg(
    value: ValueRef,
    out: *std.ArrayList(u8),
    cur_scratch_reg: []const u8,
    colors: *const ColoredGraph,
    abi: Abi,
    alloc: std.mem.Allocator,
) ![]const u8 {
    switch (value) {
        .operand => |op| return abi.regFor(op.operand, colors, .gp),
        .constant => |c| {
            switch (c) {
                .i32, .i64 => |i| {
                    try out.print(alloc, "movq ${d}, %{s}\n", .{ i, cur_scratch_reg });
                    return cur_scratch_reg;
                },
                else => return error.NotImpl,
            }
        },
    }
}

test "testing" {}
