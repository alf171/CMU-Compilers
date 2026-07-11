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
const RegisterType = @import("common").ir.RegisterType;
const valueAsImm = @import("../common.zig").valueAsImm;

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
        try out.print(alloc, "_{s}_L{d}:\n", .{ function.name, block.id });
        for (block.instructions.items) |instruction| {
            // TODO: this method should only be look at LIR. having MIR here is a hack!
            switch (instruction) {
                .lir => |l| {
                    switch (l) {
                        .constant => |c| {
                            switch (c.value) {
                                .i64, .i32 => |value| {
                                    const dst = try abi.regFor(c.dst, colors, .gp);
                                    try emitMov(out, dst, value, alloc);
                                },
                                .bool => |value| {
                                    const dst = try abi.regFor(c.dst, colors, .gp);
                                    try out.print(alloc, "\tmov {s}, #{d}\n", .{ dst, @intFromBool(value) });
                                },
                                .char => |value| {
                                    const dst = try abi.regFor(c.dst, colors, .gp);
                                    try out.print(alloc, "\tmov {s}, #{d}\n", .{ dst, value });
                                },
                                .float => |value| {
                                    const dst = try abi.regFor(c.dst, colors, .f);
                                    const bits: u64 = @bitCast(value);
                                    const scratch_reg = try abi.scratchReg(0, .gp);
                                    try emitMovUnsigned(out, scratch_reg, bits, alloc);
                                    try out.print(alloc, "\tfmov {s}, {s}\n", .{ dst, scratch_reg });
                                },
                            }
                        },
                        // str: src, dst (register -> memory)
                        .store_local => |sl| {
                            const src = try abi.regFor(sl.src, colors, .gp);
                            try emitStackStore(out, src, localOffset(sl.local.id), try abi.scratchReg(0, .gp), alloc);
                        },
                        // str
                        .store_offset => |so| {
                            const dst = try abi.regFor(so.dst.operand, colors, .gp);
                            const src = try abi.regFor(so.src.operand, colors, .gp);
                            switch (so.offset) {
                                .constant => |c| switch (c) {
                                    .i64 => |offset| {
                                        try out.print(alloc, "\tstr {s}, [{s}, #{d}]\n", .{ src, dst, offset });
                                    },
                                    else => return error.NotImpl,
                                },
                                .operand => |top| {
                                    std.debug.assert(top.type == .i64);
                                    const offset = try abi.regFor(top.operand, colors, .gp);
                                    try out.print(alloc, "\tstr {s}, [{s}, {s}]\n", .{ src, dst, offset });
                                },
                            }
                        },
                        // ldr
                        .load_offset => |lo| {
                            const dst = try abi.regFor(lo.dst.operand, colors, .gp);
                            const src = try abi.regFor(lo.src.operand, colors, .gp);
                            switch (lo.offset) {
                                .constant => |c| switch (c) {
                                    .i64 => |offset| {
                                        try out.print(alloc, "\tldr {s}, [{s}, #{d}]\n", .{ dst, src, offset });
                                    },
                                    else => return error.NotImpl,
                                },
                                .operand => |top| {
                                    const offset = try abi.regFor(top.operand, colors, .gp);
                                    switch (lo.dst.type) {
                                        .i32 => {
                                            try out.print(alloc, "\tldrsw {s}, [{s}, {s}]\n", .{ dst, src, offset });
                                        },
                                        else => {
                                            try out.print(alloc, "\tldr {s}, [{s}, {s}]\n", .{ dst, src, offset });
                                        },
                                    }
                                },
                            }
                        },
                        // ldr: dst, src (memory -> register)
                        .load_local => |ll| {
                            const dst = try abi.regFor(ll.dst, colors, .gp);
                            try emitStackLoad(out, dst, localOffset(ll.local.id), try abi.scratchReg(0, .gp), alloc);
                        },
                        .move => |m| {
                            switch (m.dst.operand) {
                                .temp => {
                                    const dst = try abi.regFor(m.dst.operand, colors, abi.regFromType(m.dst.type));
                                    switch (m.src) {
                                        // temp <- temp
                                        .temp => {
                                            const src = try abi.regFor(m.src, colors, abi.regFromType(m.dst.type));
                                            if (std.mem.eql(u8, dst, src)) continue;
                                            switch (m.dst.type) {
                                                .float => try out.print(alloc, "\tfmov {s}, {s}\n", .{ dst, src }),
                                                else => try out.print(alloc, "\tmov {s}, {s}\n", .{ dst, src }),
                                            }
                                        },
                                        // temp <- mem
                                        .mem => |slot| {
                                            const offset = spillOffset(local_stack_size, slot.id);
                                            try emitStackLoad(out, dst, offset, try abi.scratchReg(0, .gp), alloc);
                                        },
                                        // reg <- temp
                                        .reg => |reg| {
                                            switch (reg.class) {
                                                .f => {
                                                    const src = try abi.regForFromIndex(reg.id, .f);
                                                    try out.print(alloc, "\tfmov {s}, {s}\n", .{ dst, src });
                                                },
                                                .gp => {
                                                    const src = try abi.regForFromIndex(reg.id, .gp);
                                                    try out.print(alloc, "\tmov {s}, {s}\n", .{ dst, src });
                                                },
                                            }
                                        },
                                        .unknown => return error.UnexpectedState,
                                    }
                                },
                                .mem => |slot| {
                                    switch (m.src) {
                                        // mem <- reg
                                        .temp => {
                                            const offset = spillOffset(local_stack_size, slot.id);
                                            const src = try abi.regFor(m.src, colors, .gp);
                                            try emitStackStore(out, src, offset, try abi.scratchReg(0, .gp), alloc);
                                        },
                                        .mem => {
                                            return error.MemoryToMemoryMoveDetected;
                                        },
                                        else => return error.NotImpl,
                                    }
                                },
                                .reg => |reg| {
                                    switch (m.src) {
                                        // reg <- temp
                                        .temp => {
                                            const src = try abi.regFor(m.src, colors, reg.class);
                                            switch (reg.class) {
                                                .f => try out.print(alloc, "\tfmov {s}, {s}\n", .{ try abi.paramRegFor(reg.id, .f), src }),
                                                .gp => try out.print(alloc, "\tmov {s}, {s}\n", .{ try abi.paramRegFor(reg.id, .gp), src }),
                                            }
                                        },
                                        else => |e| {
                                            std.debug.print("{s} not impl!\n", .{@tagName(e)});
                                            return error.NotImpl;
                                        },
                                    }
                                },
                                .unknown => return error.UnexpectedState,
                            }
                        },
                        .binop => |binop| {
                            const dst = try abi.regFor(binop.dst.operand, colors, abi.regFromType(binop.dst.type));
                            const lhs = try valueToReg(binop.lhs, out, try abi.scratchReg(1, .gp), colors, abi, alloc);

                            switch (binop.op) {
                                // can use imm
                                .add => {
                                    switch (binop.dst.type) {
                                        .float => try out.print(alloc, "\tfadd ", .{}),
                                        else => try out.print(alloc, "\tadd ", .{}),
                                    }
                                    if (valueAsImm(binop.rhs)) |rhs_imm| {
                                        try out.print(alloc, "{s}, {s}, #{d}\n", .{ dst, lhs, rhs_imm });
                                    } else {
                                        const rhs = try abi.regFor(binop.rhs.operand.operand, colors, .gp);
                                        try out.print(alloc, "{s}, {s}, {s}\n", .{ dst, lhs, rhs });
                                    }
                                },
                                .sub => {
                                    switch (binop.dst.type) {
                                        .float => try out.print(alloc, "\tfsub ", .{}),
                                        else => try out.print(alloc, "\tsub ", .{}),
                                    }
                                    if (valueAsImm(binop.rhs)) |rhs_imm| {
                                        try out.print(alloc, "{s}, {s}, #{d}\n", .{ dst, lhs, rhs_imm });
                                    } else {
                                        const rhs = try abi.regFor(binop.rhs.operand.operand, colors, abi.regFromType(binop.rhs.operand.type));
                                        try out.print(alloc, "{s}, {s}, {s}\n", .{ dst, lhs, rhs });
                                    }
                                },
                                // cant use imm
                                .mul => {
                                    const reg_type = abi.regFromType(binop.dst.type);
                                    const rhs_reg = try valueToReg(binop.rhs, out, try abi.scratchReg(0, reg_type), colors, abi, alloc);
                                    switch (binop.dst.type) {
                                        .float => try out.print(alloc, "\tfmul {s}, {s}, {s}\n", .{ dst, lhs, rhs_reg }),
                                        else => try out.print(alloc, "\tmul {s}, {s}, {s}\n", .{ dst, lhs, rhs_reg }),
                                    }
                                },
                                .div => {
                                    const rhs_reg = try valueToReg(binop.rhs, out, try abi.scratchReg(0, .gp), colors, abi, alloc);
                                    switch (binop.dst.type) {
                                        .float => try out.print(alloc, "\tfdiv {s}, {s}, {s}\n", .{ dst, lhs, rhs_reg }),
                                        else => try out.print(alloc, "\tsdiv {s}, {s}, {s}\n", .{ dst, lhs, rhs_reg }),
                                    }
                                },
                                .mod => {
                                    const scratch_reg = try abi.scratchReg(0, .gp);
                                    const scratch_reg_2 = try abi.scratchReg(1, .gp);
                                    const rhs_reg = try valueToReg(binop.rhs, out, scratch_reg_2, colors, abi, alloc);
                                    try out.print(alloc, "\tsdiv {s}, {s}, {s}\n", .{ scratch_reg, lhs, rhs_reg });
                                    try out.print(alloc, "\tmsub {s}, {s}, {s}, {s}\n", .{ dst, scratch_reg, rhs_reg, lhs });
                                },
                                .lshift => {
                                    switch (binop.rhs) {
                                        .constant => |c| {
                                            const i = switch (c) {
                                                .i64, .i32 => |b| b,
                                                else => error.NotImpl,
                                            };
                                            try out.print(alloc, "\tlsl {s}, {s}, {d}\n", .{ dst, lhs, try i });
                                        },
                                        .operand => |top| {
                                            const rhs = try abi.regFor(top.operand, colors, .gp);
                                            try out.print(alloc, "\tlsl {s}, {s}, {s}\n", .{ dst, lhs, rhs });
                                        },
                                    }
                                },
                                .rshift => {
                                    switch (binop.rhs) {
                                        .constant => |c| {
                                            const i = switch (c) {
                                                .i64, .i32 => |b| b,
                                                else => error.NotImpl,
                                            };
                                            try out.print(alloc, "\tlsr {s}, {s}, {d}\n", .{ dst, lhs, try i });
                                        },
                                        .operand => |top| {
                                            const rhs = try abi.regFor(top.operand, colors, .gp);
                                            try out.print(alloc, "\tlsr {s}, {s}, {s}\n", .{ dst, lhs, rhs });
                                        },
                                    }
                                },
                                else => |op| {
                                    std.debug.print("op is not supported {s}\n", .{@tagName(op)});
                                    return error.NotSupported;
                                },
                            }
                        },
                        .branch => |b| {
                            const cond = try abi.regFor(b.condition, colors, .gp);
                            try out.print(alloc, "\tcmp {s}, #0\n", .{cond});
                            try out.print(alloc, "\tb.ne _{s}_L{d}\n", .{ function.name, b.then_block });
                            try out.print(alloc, "\tb _{s}_L{d}\n", .{ function.name, b.else_block });
                        },
                        .jump => |j| {
                            try out.print(alloc, "\tb _{s}_L{d}\n", .{ function.name, j.target });
                        },
                        // x29 - 8  local: items pointer
                        // x29 - 16 array[2]
                        // x29 - 24 array[1]
                        // x29 - 32 array[0]  <- array_base
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

                            // array[i] = x29 - end + adjust(i)
                            const base_offset = arrayOffset(local_count, base_slot + tuple_slots - 1);
                            var cur_offset: usize = 0;
                            for (tl.elements, 0..) |elem, i| {
                                const src = switch (elem) {
                                    .operand => try abi.regFor(elem.operand.operand, colors, .gp),
                                    .constant => |c| blk: {
                                        const scratch_reg = try abi.scratchReg(0, .gp);
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
                                    .i64, .i32 => try emitStackStore(out, src, offset, try abi.scratchReg(0, .gp), alloc),
                                    .bool, .char => try emitStackStoreByte(out, src, offset, try abi.scratchReg(0, .gp), alloc),
                                    else => return error.NotImpl,
                                }
                                cur_offset += try elem_type.sizeOfType();
                            }
                            // array_base = x29 - end
                            try out.print(alloc, "\tsub {s}, x29, #{d}\n", .{ dst, base_offset });
                        },
                        .tuple_load => |tl| {
                            const dst = try abi.regFor(tl.dst, colors, .gp);
                            const index = try abi.regFor(tl.index, colors, .gp);
                            const tuple = try abi.regFor(tl.tuple.operand, colors, .gp);

                            const elem_type = try getElementType(tl.tuple.type);
                            switch (elem_type) {
                                // index = index << 3
                                .i64, .i32 => {
                                    const scratch_reg = try abi.scratchReg(0, .gp);
                                    try out.print(alloc, "\tlsl {s}, {s}, #3\n", .{ scratch_reg, index });
                                    try out.print(alloc, "\tldr {s}, [{s}, {s}]\n", .{ dst, tuple, scratch_reg });
                                },
                                .bool => {
                                    try out.print(alloc, "\tldr w{s}, [{s}, {s}]\n", .{ dst[1..], tuple, index });
                                },
                                else => return error.TypeNotImpl,
                            }
                        },
                        .compare => |c| {
                            const dst = try abi.regFor(c.dst.operand, colors, .gp);
                            switch (c.lhs.type) {
                                .float => {
                                    const lhs = try abi.regFor(c.lhs.operand, colors, .f);
                                    const rhs = try abi.regFor(c.rhs.operand, colors, .f);
                                    try out.print(alloc, "\tfcmp {s}, {s}\n", .{ lhs, rhs });
                                    try out.print(alloc, "\tcset {s}, {s}\n", .{ dst, condForCmp(c.op) });
                                },
                                else => {
                                    const lhs = try abi.regFor(c.lhs.operand, colors, .gp);
                                    const rhs = try abi.regFor(c.rhs.operand, colors, .gp);
                                    try out.print(alloc, "\tcmp {s}, {s}\n", .{ lhs, rhs });
                                    try out.print(alloc, "\tcset {s}, {s}\n", .{ dst, condForCmp(c.op) });
                                },
                            }
                        },
                        .select => |s| {
                            const dst = try abi.regFor(s.dst, colors, .gp);
                            const scratch_reg = try abi.scratchReg(0, .gp);
                            const if_reg = try valueToReg(s.if_value, out, scratch_reg, colors, abi, alloc);
                            const scratch_reg_2 = try abi.scratchReg(1, .gp);
                            const else_reg = try valueToReg(s.else_value, out, scratch_reg_2, colors, abi, alloc);

                            const condition = try abi.regFor(s.condition, colors, .gp);
                            try out.print(alloc, "\tcmp {s}, #0\n", .{condition});
                            try out.print(alloc, "\tcsel {s}, {s}, {s}, ne\n", .{ dst, if_reg, else_reg });
                        },
                        .unaryop => |u| {
                            switch (u.op) {
                                .neg => switch (u.dst.type) {
                                    .float => {
                                        const dst = try abi.regFor(u.dst.operand, colors, .f);
                                        const src = try abi.regFor(u.src, colors, .f);
                                        try out.print(alloc, "\tfneg {s}, {s}\n", .{ dst, src });
                                    },
                                    else => {
                                        const dst = try abi.regFor(u.dst.operand, colors, .gp);
                                        const src = try abi.regFor(u.src, colors, .gp);
                                        try out.print(alloc, "\tneg {s}, {s}\n", .{ dst, src });
                                    },
                                },
                            }
                        },
                        else => |lir| {
                            std.debug.panic("ir instruction doesnt have a mapping in arm backend: {s}\n", .{@tagName(lir)});
                            return error.NotSupported;
                        },
                    }
                },
                .len => |l| {
                    const dst = try abi.regFor(l.dst.operand, colors, .gp);
                    const src = try abi.regFor(l.value.operand, colors, .gp);
                    switch (l.value.type) {
                        .list => {
                            try out.print(alloc, "\tldr {s}, [{s}]\n", .{ dst, src });
                        },
                        else => |e| {
                            std.debug.print("len called on {s} unexpectedly\n", .{@tagName(e)});
                            return error.InvalidLenCall;
                        },
                    }
                },
                // abi specific component are handled in pre_color
                .function_call => |fc| {
                    switch (fc.callee) {
                        .direct => |function_name| {
                            try out.print(alloc, "\tbl _{s}\n", .{function_name});
                        },
                        .indirect => |ind| {
                            const addr = try abi.regFor(ind.operand, colors, .gp);
                            try out.print(alloc, "\tblr {s}\n", .{addr});
                        },
                    }
                },
                // abi specific component are handled in pre_color
                .function_return => {
                    try out.print(alloc, "\tb _{s}_epilogue\n", .{function.name});
                },
                .function_ref => |fr| {
                    const dst = try abi.regFor(fr.dst.operand, colors, .gp);
                    try out.print(alloc, "\tadrp {s}, _{s}@PAGE\n", .{ dst, fr.function_name });
                    try out.print(alloc, "\tadd {s}, {s}, _{s}@PAGEOFF\n", .{ dst, dst, fr.function_name });
                },
                .cast => |c| {
                    // type a -> type b
                    switch (c.src.type) {
                        .i64 => switch (c.dst_target_type) {
                            .float => {
                                const dst = try abi.regFor(c.dst, colors, .f);
                                const src = try abi.regFor(c.src.operand, colors, .gp);
                                try out.print(alloc, "\tscvtf {s}, {s}\n", .{ dst, src });
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
                                try out.print(alloc, "\tfcvtzs {s}, {s}\n", .{ dst, src });
                            },
                            else => return error.UnsupportedCast,
                        },
                        else => return error.UnsupportedCast,
                    }
                },
                else => |ir| {
                    std.debug.panic("ir instruction doesnt have a mapping in arm backend: {s}\n", .{@tagName(ir)});
                    return error.NotSupported;
                },
            }
        }
        if (block.successors.items.len == 0) {
            try out.print(alloc, "\tb _{s}_epilogue\n", .{function.name});
        }
    }
    try createFunctionFooter(out, function.name, frame_stack_size, is_main, abi, alloc);
}

fn createProgramHeader(out: *ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, ".section __TEXT,__text\n");
    try out.appendSlice(alloc, ".global _main\n");
}

fn createFunctionHeader(out: *ArrayList(u8), name: []const u8, local_stack_size: usize, abi: Abi, alloc: std.mem.Allocator) !void {
    try out.print(alloc, "_{s}:\n", .{name});
    try out.appendSlice(alloc, "\tstp x29, x30, [sp, #-16]!\n");
    try out.appendSlice(alloc, "\tmov x29, sp\n");
    if (local_stack_size > 0) {
        try out.print(alloc, "\tsub sp, sp, #{d}\n", .{local_stack_size});
    }
    try saveCalleeSaveReg(out, abi, alloc);
}

fn saveCalleeSaveReg(out: *ArrayList(u8), abi: Abi, alloc: std.mem.Allocator) !void {
    // FIXME: talk through abi apis instead
    std.debug.assert(abi.gp_callee_save_regs.len % 2 == 0);
    var i: usize = 0;
    while (i < abi.gp_callee_save_regs.len) : (i += 2) {
        const reg1 = abi.gp_callee_save_regs[i];
        const reg2 = abi.gp_callee_save_regs[i + 1];
        try out.print(alloc, "\tstp {s}, {s}, [sp, #-16]!\n", .{ reg1, reg2 });
    }
}

fn restoreCallleeSafeReg(out: *ArrayList(u8), abi: Abi, alloc: std.mem.Allocator) !void {
    // FIXME: talk through abi apis instead
    std.debug.assert(abi.gp_callee_save_regs.len % 2 == 0);
    var i: usize = abi.gp_callee_save_regs.len;
    while (i > 0) {
        i -= 2;
        const reg1 = abi.gp_callee_save_regs[i];
        const reg2 = abi.gp_callee_save_regs[i + 1];
        try out.print(alloc, "\tldp {s}, {s}, [sp], #16\n", .{ reg1, reg2 });
    }
}

fn emitStackLoad(
    out: *ArrayList(u8),
    dst: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    if (offset <= 256) {
        try out.print(alloc, "\tldr {s}, [x29, #-{d}]\n", .{ dst, offset });
    } else {
        try out.print(alloc, "\tsub {s}, x29, #{d}\n", .{ scratch, offset });
        try out.print(alloc, "\tldr {s}, [{s}]\n", .{ dst, scratch });
    }
}

fn emitStackLoadByte(
    out: *ArrayList(u8),
    dst: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    std.debug.assert(dst[0] == 'x');
    if (offset <= 256) {
        try out.print(alloc, "\tldrb w{s}, [x29, #-{d}]\n", .{ dst[1..], offset });
    } else {
        try out.print(alloc, "\tsub {s}, x29, #{d}\n", .{ scratch, offset });
        try out.print(alloc, "\tldrb w{s}, [{s}]\n", .{ dst[1..], scratch });
    }
}

fn emitStackStore(
    out: *ArrayList(u8),
    src: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    if (offset <= 256) {
        try out.print(alloc, "\tstr {s}, [x29, #-{d}]\n", .{ src, offset });
    } else {
        try out.print(alloc, "\tsub {s}, x29, #{d}\n", .{ scratch, offset });
        try out.print(alloc, "\tstr {s}, [{s}]\n", .{ src, scratch });
    }
}

fn emitStackStoreByte(
    out: *ArrayList(u8),
    src: []const u8,
    offset: usize,
    scratch: []const u8,
    alloc: std.mem.Allocator,
) !void {
    if (offset <= 256) {
        try out.print(alloc, "\tstrb w{s}, [x29, #-{d}]\n", .{ src[1..], offset });
    } else {
        try out.print(alloc, "\tsub {s}, x29, #{d}\n", .{ scratch, offset });
        try out.print(alloc, "\tstrb w{s}, [{s}]\n", .{ src[1..], scratch });
    }
}

fn createFunctionFooter(out: *ArrayList(u8), name: []const u8, local_stack_size: usize, is_main: bool, abi: Abi, alloc: std.mem.Allocator) !void {
    try out.print(alloc, "_{s}_epilogue:\n", .{name});
    if (is_main) {
        try out.appendSlice(alloc, "\tbl _arena_free\n");
        try out.appendSlice(alloc, "\tmov w0, #0\n");
    }

    try restoreCallleeSafeReg(out, abi, alloc);
    if (local_stack_size > 0) {
        try out.print(alloc, "\tadd sp, sp, #{d}\n", .{local_stack_size});
    }

    // restore frame pointer and return address
    try out.appendSlice(alloc, "\tldp x29, x30, [sp], #16\n");
    try out.appendSlice(alloc, "\tret\n");
}

fn createFooter(out: *ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, "\n.section __TEXT,__cstring\n");
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
        .eq => "eq",
        .neq => "ne",
        .lt => "lt",
        .lte => "le",
        .gt => "gt",
        .gte => "ge",
    };
}

// TODO: emitMov is more generic than this
fn valueToReg(
    value: ValueRef,
    out: *std.ArrayList(u8),
    cur_scratch_reg: []const u8,
    colors: *const ColoredGraph,
    abi: Abi,
    alloc: std.mem.Allocator,
) ![]const u8 {
    switch (value) {
        .operand => |op| return abi.regFor(op.operand, colors, abi.regFromType(op.type)),
        .constant => |c| {
            switch (c) {
                .float => |f| {
                    try out.print(alloc, "fmov {s}, #{}\n", .{ cur_scratch_reg, f });
                    return cur_scratch_reg;
                },
                .i32, .i64 => |i| {
                    try out.print(alloc, "mov {s}, #{d}\n", .{ cur_scratch_reg, i });
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

fn getRegPrefix(size: usize) ![]const u8 {
    return switch (size) {
        1, 4 => "w",
        8 => "x",
        else => error.NotImpl,
    };
}
