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
                .function_ref => |fr| {
                    const dst = try abi.regFor(fr.dst.operand, colors, abi.regFromType(fr.dst.type));
                    try out.print(alloc, "\tleaq {s}(%rip), %{s}\n", .{ fr.function_name, dst });
                },
                .function_call => |fc| {
                    switch (fc.callee) {
                        .direct => |function_name| {
                            try out.print(alloc, "\tcallq {s}\n", .{function_name});
                        },
                        .indirect => |top| {
                            const fn_op = try abi.regFor(top.operand, colors, abi.regFromType(top.type));
                            try out.print(alloc, "\tcallq *%{s}\n", .{fn_op});
                        },
                    }
                },
                .function_return => {
                    try out.print(alloc, "\tjmp {s}_epilogue\n", .{function.name});
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
                            .top => |top| try abi.regFor(top.operand, colors, .gp),
                            .constant => |c| blk: {
                                const scratch_reg = try abi.scratchReg(0, abi.regFromType(c.toType()));
                                try emitConstantToReg(out, scratch_reg, c, alloc);
                                break :blk scratch_reg;
                            },
                        };

                        const offset = base_offset - cur_offset;

                        const elem_type = switch (tl.dst.type) {
                            .tuple => |tuple| tuple.elements[i],
                            else => return error.WrongType,
                        };

                        switch (elem_type) {
                            .i64, .i32 => try emitStackStore(out, src, offset, alloc),
                            .bool, .char => try emitStackStoreByte(out, src, offset, alloc),
                            else => return error.NotImpl,
                        }
                        cur_offset += try elem_type.sizeOfType();
                    }
                    // array_base = x29 - end
                    try out.print(alloc, "\tleaq -{d}(%rbp), %{s}\n", .{ base_offset, dst });
                },
                .lir => |l| {
                    switch (l) {
                        .move => |m| {
                            switch (m.src) {
                                .constant => |c| {
                                    const dst = try abi.regFor(m.dst.operand, colors, abi.regFromType(m.dst.type));
                                    switch (c) {
                                        .i32, .i64, .char, .bool => {
                                            try out.print(alloc, "\tmovq ${d}, %{s}\n", .{ try c.valueAsIntImm(), dst });
                                        },
                                        .float => |f| {
                                            const gp_scratch_reg = try abi.scratchReg(0, .gp);
                                            const bits: u64 = @bitCast(f);
                                            try out.print(alloc, "\tmovabsq ${d}, %{s}\n", .{ bits, gp_scratch_reg });
                                            try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ gp_scratch_reg, dst });
                                        },
                                    }
                                },
                                .top => |src_top| {
                                    const mov_isnt = if (m.dst.type == .float) "movsd" else "movq";
                                    switch (m.dst.operand) {
                                        .temp => {
                                            switch (src_top.operand) {
                                                .temp, .reg => {
                                                    const dst = try abi.regFor(m.dst.operand, colors, abi.regFromType(m.dst.type));
                                                    const src = try abi.regFor(src_top.operand, colors, abi.regFromType(src_top.type));
                                                    try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mov_isnt, src, dst });
                                                },
                                                .mem => |mem| {
                                                    const dst = try abi.regFor(m.dst.operand, colors, abi.regFromType(m.dst.type));
                                                    const offset = spillOffset(local_stack_size, mem.id);
                                                    try out.print(alloc, "\tmovq -{d}(%rbp), %{s}\n", .{ offset, dst });
                                                },
                                                else => |e| {
                                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                                    return error.NotImpl;
                                                },
                                            }
                                        },
                                        .reg => {
                                            switch (src_top.operand) {
                                                .temp => {
                                                    const dst = try abi.regFor(m.dst.operand, colors, abi.regFromType(m.dst.type));
                                                    const src = try abi.regFor(src_top.operand, colors, abi.regFromType(src_top.type));
                                                    try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mov_isnt, src, dst });
                                                },
                                                else => |e| {
                                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                                    return error.NotImpl;
                                                },
                                            }
                                        },
                                        .mem => |mem| {
                                            switch (src_top.operand) {
                                                .temp => {
                                                    const src = try abi.regFor(src_top.operand, colors, abi.regFromType(src_top.type));
                                                    const offset = spillOffset(local_stack_size, mem.id);
                                                    try out.print(alloc, "\tmovq %{s}, -{d}(%rbp)\n", .{ src, offset });
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
                            }
                        },
                        .store_offset => |so| {
                            const dst = try abi.regFor(so.dst.operand, colors, .gp);
                            const src = try abi.regFor(so.src.operand, colors, .gp);
                            switch (so.offset) {
                                .constant => |c| switch (c) {
                                    .i64 => |offset| {
                                        try out.print(alloc, "\tmovq %{s}, {d}(%{s})\n", .{ src, offset, dst });
                                    },
                                    else => return error.NotImpl,
                                },
                                .top => |top| {
                                    std.debug.assert(top.type == .i64);
                                    const offset = try abi.regFor(top.operand, colors, .gp);
                                    switch (so.src.type) {
                                        .i32 => {
                                            try out.print(alloc, "\tmovl %{s}, (%{s},%{s})\n", .{ reg32(src), dst, offset });
                                        },
                                        .char => {
                                            try out.print(alloc, "\tmovb %{s}, (%{s},%{s})\n", .{ reg8(src), dst, offset });
                                        },
                                        else => {
                                            try out.print(alloc, "\tmovq %{s}, (%{s},%{s})\n", .{ src, dst, offset });
                                        },
                                    }
                                },
                            }
                        },
                        .binop => |bop| {
                            const dst = try abi.regFor(bop.dst.operand, colors, abi.regFromType(bop.dst.type));
                            const lhs = try abi.regFor(bop.lhs.operand, colors, abi.regFromType(bop.lhs.type));
                            const rhs = try abi.regFor(bop.rhs.operand, colors, abi.regFromType(bop.rhs.type));

                            switch (bop.op) {
                                .add => {
                                    const add_inst = if (bop.dst.type == .float) "addsd" else "addq";
                                    if (std.mem.eql(u8, dst, rhs)) {
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ add_inst, lhs, dst });
                                    } else if (!std.mem.eql(u8, dst, lhs)) {
                                        try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ lhs, dst });
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ add_inst, rhs, dst });
                                    } else {
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ add_inst, rhs, dst });
                                    }
                                },
                                .sub => {
                                    const sub_inst = if (bop.dst.type == .float) "subsd" else "subq";
                                    const mov_inst = if (bop.dst.type == .float) "movsd" else "movq";
                                    if (std.mem.eql(u8, dst, rhs)) {
                                        const scratch_reg = try abi.scratchReg(0, abi.regFromType(bop.dst.type));
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mov_inst, rhs, scratch_reg });
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mov_inst, lhs, dst });
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ sub_inst, scratch_reg, dst });
                                    } else if (!std.mem.eql(u8, dst, lhs)) {
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mov_inst, lhs, dst });
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ sub_inst, rhs, dst });
                                    } else {
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ sub_inst, rhs, dst });
                                    }
                                },
                                .mul => {
                                    const mult_inst = if (bop.dst.type == .float) "mulsd" else "imulq";
                                    if (std.mem.eql(u8, dst, lhs)) {
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mult_inst, rhs, dst });
                                    } else if (std.mem.eql(u8, dst, rhs)) {
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mult_inst, lhs, dst });
                                    } else {
                                        try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ lhs, dst });
                                        try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ mult_inst, rhs, dst });
                                    }
                                },
                                .div => {
                                    try out.print(alloc, "\tpushq %rax\n", .{});
                                    try out.print(alloc, "\tmovq %{s}, %rax\n", .{lhs});
                                    try out.print(alloc, "\tcqto\n", .{});
                                    try out.print(alloc, "\tidivq %{s}\n", .{rhs});
                                    // x86 magic :)
                                    try out.print(alloc, "\tmovq %rax, %{s}\n", .{dst});
                                    try out.print(alloc, "\tpopq %rax\n", .{});
                                },
                                .mod => {
                                    try out.print(alloc, "\tpushq %rax\n", .{});
                                    try out.print(alloc, "\tmovq %{s}, %rax\n", .{lhs});
                                    try out.print(alloc, "\tcqto\n", .{});
                                    try out.print(alloc, "\tidivq %{s}\n", .{rhs});
                                    // x86 magic :)
                                    try out.print(alloc, "\tmovq %rdx, %{s}\n", .{dst});
                                    try out.print(alloc, "\tpopq %rax\n", .{});
                                },
                                .lshift, .rshift => {
                                    if (bop.lhs.type == .float) {
                                        return error.InvalidFloat;
                                    }
                                    const shift_inst = switch (bop.op) {
                                        .lshift => "shlq",
                                        .rshift => "sarq",
                                        else => unreachable,
                                    };
                                    const scratch = try abi.scratchReg(0, .gp);
                                    try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ lhs, scratch });
                                    try out.print(alloc, "\tpushq %rcx\n", .{});
                                    try out.print(alloc, "\tmovq %{s}, %rcx\n", .{rhs});
                                    try out.print(alloc, "\t{s} %{s}, %{s}\n", .{ shift_inst, reg8("rcx"), scratch });
                                    try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ scratch, dst });
                                    try out.print(alloc, "\tpopq %rcx\n", .{});
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
                            try out.print(alloc, "\tcmpq %{s}, %{s}\n", .{ rhs, lhs });
                            try out.print(alloc, "\t{s} %r10b\n", .{condForCmp(c.op)});
                            try out.print(alloc, "\tmovzbq %r10b, %{s}\n", .{dst});
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
                        .select => |s| {
                            const scratch_reg = try abi.scratchReg(0, .gp);
                            // TODO: dont use two scratch regs!
                            const scratch_reg_2 = try abi.scratchReg(1, .gp);
                            const dst = try abi.regFor(s.dst, colors, .gp);
                            const if_reg = try valueToReg(s.if_value, out, scratch_reg, colors, abi, alloc);
                            const else_reg = try valueToReg(s.else_value, out, scratch_reg_2, colors, abi, alloc);

                            const condition = try abi.regFor(s.condition, colors, .gp);

                            try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ else_reg, dst });
                            try out.print(alloc, "\tcmpq $0, %{s}\n", .{condition});
                            try out.print(alloc, "\tcmovne %{s}, %{s}\n", .{ if_reg, dst });
                        },
                        .unaryop => |u| {
                            const dst = try abi.regFor(u.dst.operand, colors, abi.regFromType(u.dst.type));
                            const src = try abi.regFor(u.src, colors, abi.regFromType(u.dst.type));
                            try out.print(alloc, "\t movq %{s}, %{s}\n", .{ src, dst });
                            switch (u.op) {
                                .neg => switch (u.dst.type) {
                                    .float => {
                                        const fp_scratch_reg = try abi.scratchReg(0, .f);
                                        const gp_scratch_reg = try abi.scratchReg(0, .gp);
                                        try out.print(alloc, "\tmovabsq $0x8000000000000000, %{s}\n", .{gp_scratch_reg});
                                        try out.print(alloc, "\tmovq %{s}, %{s}\n", .{ fp_scratch_reg, gp_scratch_reg });
                                    },
                                    else => try out.print(alloc, "\tnegq %{s}\n", .{dst}),
                                },
                            }
                        },
                        .cast => |c| {
                            // type a -> type b
                            switch (c.src.type) {
                                .i64 => switch (c.dst_target_type) {
                                    .float => {
                                        const dst = try abi.regFor(c.dst, colors, .f);
                                        const src = try abi.regFor(c.src.operand, colors, .gp);
                                        try out.print(alloc, "\tcvtsi2sdq %{s}, %{s}\n", .{ src, dst });
                                    },
                                    else => {
                                        std.debug.print("unsupported cast: {s} -> {s}\n", .{
                                            @tagName(c.src.type),
                                            @tagName(c.dst_target_type),
                                        });
                                        return error.UnsupportedCast;
                                    },
                                },
                                .float => switch (c.dst_target_type) {
                                    .i64 => {
                                        const dst = try abi.regFor(c.dst, colors, .gp);
                                        const src = try abi.regFor(c.src.operand, colors, .f);
                                        try out.print(alloc, "\tcvttsd2siq %{s}, %{s}\n", .{ src, dst });
                                    },
                                    else => return error.UnsupportedCast,
                                },
                                else => return error.UnsupportedCast,
                            }
                        },
                        .load_offset => |lo| {
                            const dst = try abi.regFor(lo.dst.operand, colors, .gp);
                            const src = try abi.regFor(lo.src.operand, colors, .gp);
                            switch (lo.offset) {
                                .constant => |c| switch (c) {
                                    .i64 => |offset| {
                                        try out.print(alloc, "\tmovq {d}(%{s}), %{s}\n", .{ offset, src, dst });
                                    },
                                    else => return error.NotImpl,
                                },
                                .top => |top| {
                                    const offset = try abi.regFor(top.operand, colors, .gp);
                                    switch (lo.dst.type) {
                                        .float => {
                                            try out.print(alloc, "\tmovsd (%{s},%{s}), %{s}\n", .{ offset, src, dst });
                                        },
                                        .i32 => {
                                            try out.print(alloc, "\tmovslq (%{s},%{s}), %{s}\n", .{ offset, src, dst });
                                        },
                                        else => {
                                            try out.print(alloc, "\tmovq (%{s},%{s}), %{s}\n", .{ offset, src, dst });
                                        },
                                    }
                                },
                            }
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
    alloc: std.mem.Allocator,
) !void {
    try out.print(alloc, "\tmovq %{s}, -{d}(%rbp)\n", .{ src, offset });
}

fn emitStackStoreByte(
    out: *ArrayList(u8),
    src: []const u8,
    offset: usize,
    alloc: std.mem.Allocator,
) !void {
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
                .tuple_literal => |al| slots += al.elements.len,
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
        .top => |top| return abi.regFor(top.operand, colors, abi.regFromType(top.type)),
        .constant => |c| {
            switch (c) {
                .i32, .i64 => |i| {
                    try out.print(alloc, "movq ${d}, %{s}\n", .{ i, cur_scratch_reg });
                    return cur_scratch_reg;
                },
                .float => |f| {
                    const bits: u64 = @bitCast(f);
                    try out.print(alloc, "\tmovabsq ${d}, %{s}\n", .{ bits, cur_scratch_reg });
                    return cur_scratch_reg;
                },
                else => |e| {
                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                    return error.NotImpl;
                },
            }
        },
    }
}

fn reg32(reg: []const u8) []const u8 {
    if (std.mem.eql(u8, reg, "rsi")) return "esi";
    if (std.mem.eql(u8, reg, "rdi")) return "edi";
    if (std.mem.eql(u8, reg, "rdx")) return "edx";
    if (std.mem.eql(u8, reg, "rcx")) return "ecx";
    if (std.mem.eql(u8, reg, "rax")) return "eax";
    if (std.mem.eql(u8, reg, "rbx")) return "ebx";
    if (std.mem.eql(u8, reg, "r8")) return "r8d";
    if (std.mem.eql(u8, reg, "r9")) return "r9d";
    if (std.mem.eql(u8, reg, "r12")) return "r12d";
    if (std.mem.eql(u8, reg, "r13")) return "r13d";
    if (std.mem.eql(u8, reg, "r14")) return "r14d";
    if (std.mem.eql(u8, reg, "r15")) return "r15d";
    unreachable;
}

fn reg8(reg: []const u8) []const u8 {
    if (std.mem.eql(u8, reg, "rsi")) return "sil";
    if (std.mem.eql(u8, reg, "rdi")) return "dil";
    if (std.mem.eql(u8, reg, "rdx")) return "dl";
    if (std.mem.eql(u8, reg, "rcx")) return "cl";
    if (std.mem.eql(u8, reg, "rax")) return "al";
    if (std.mem.eql(u8, reg, "rbx")) return "bl";
    if (std.mem.eql(u8, reg, "r8")) return "r8b";
    if (std.mem.eql(u8, reg, "r9")) return "r9b";
    if (std.mem.eql(u8, reg, "r12")) return "r12b";
    if (std.mem.eql(u8, reg, "r13")) return "r13b";
    if (std.mem.eql(u8, reg, "r14")) return "r14b";
    if (std.mem.eql(u8, reg, "r15")) return "r15b";
    unreachable;
}

test "testing" {}
