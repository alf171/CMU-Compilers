const std = @import("std");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const TypeInfo = common.types.TypeInfo;
const sizeOfType = common.types.sizeOfType;
const Block = common.ir.BasicBlock;
const Function = common.ir.Function;
const getElementType = common.types.getElementType;
const color = @import("middle").color;
const regFor = @import("reg.zig").regFor;
const paramRegFor = @import("reg.zig").paramRegFor;
const FirstParamRegister = @import("reg.zig").first_param_reg;
const CalleeSafeRegisters = @import("reg.zig").callee_safe_regs;
const CalleReturnRegister = @import("reg.zig").callee_return_reg;
const ScratchReg = @import("reg.zig").scratch_reg;

pub fn emit(program: *const common.ir.Program, colors: *const color.ColoredGraph, alloc: std.mem.Allocator) ![]u8 {
    var out = ArrayList(u8).init(alloc);
    errdefer out.deinit();

    try createProgramHeader(&out);
    try emitFunction(&out, colors, &program.main, true);
    for (program.functions.items) |function| {
        try emitFunction(&out, colors, &function, false);
    }

    try createFooter(&out);

    return out.toOwnedSlice();
}

fn emitFunction(
    out: *ArrayList(u8),
    colors: *const color.ColoredGraph,
    function: *const Function,
    is_main: bool,
) !void {
    const local_count = countLocals(&function.blocks);
    const array_slot_count = countArraySlots(&function.blocks);
    const local_stack_size = std.mem.alignForward(
        usize,
        (array_slot_count + local_count) * 8,
        16,
    );
    try createFunctionHeader(out, function.name, local_stack_size);
    var next_array_slot: usize = 0;
    for (function.blocks.items) |block| {
        try out.print("_{s}_L{d}:\n", .{ function.name, block.id });
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .constant => |c| {
                    const dst = try regFor(c.dst, colors);
                    switch (c.value) {
                        .int => |value| {
                            try out.print("\tmov {s}, #{d}\n", .{ dst, value });
                        },
                        .bool => |value| {
                            try out.print("\tmov {s}, #{d}\n", .{ dst, @intFromBool(value) });
                        },
                        .char => |value| {
                            try out.print("\tmov {s}, #{d}\n", .{ dst, value });
                        },
                        else => return error.NotImpl,
                    }
                },
                // str: src, dst (register -> memory)
                .store_local => |sl| {
                    const src = try regFor(sl.src, colors);
                    try out.print("\tstr {s}, [x29, #-{d}]\n", .{ src, localOffset(sl.local.id) });
                },
                // ldr: dst, src (memory -> register)
                .load_local => |ll| {
                    const dst = try regFor(ll.dst, colors);
                    try out.print("\tldr {s}, [x29, #-{d}]\n", .{ dst, localOffset(ll.local.id) });
                },
                .move => |m| {
                    const dst = try regFor(m.dst, colors);
                    const src = try regFor(m.src, colors);
                    try out.print("\tmov {s}, {s}\n", .{ dst, src });
                },
                .print => |p| {
                    switch (p.type) {
                        .int, .bool => {
                            const src = try regFor(p.src, colors);
                            try out.appendSlice("\tsub sp, sp, #16\n");
                            try out.print("\tstr {s}, [sp]\n", .{src});
                            try out.appendSlice("\tadrp x0, fmt@PAGE\n");
                            try out.appendSlice("\tadd x0, x0, fmt@PAGEOFF\n");
                            try out.appendSlice("\tbl _printf\n");
                            try out.appendSlice("\tadd sp, sp, #16\n");
                        },
                        .array => |arr| {
                            if (arr.element.* != .char) return error.TypeNotImpl;
                            const src = try regFor(p.src, colors);
                            for (0..(arr.size orelse return error.SizeMissing)) |i| {
                                const offset = i * 8;
                                try out.print("\tldr {s}, [{s}, #{d}]\n", .{ FirstParamRegister, src, offset });
                                try out.appendSlice("\tbl _putchar\n");
                            }
                            // print \n
                            try out.print("\tmov x0, #10\n", .{});
                            try out.appendSlice("\tbl _putchar\n");
                        },
                        .list => |lst| {
                            if (lst.element.* != .char) return error.TypeNotImpl;
                            const src = try regFor(p.src, colors);
                            try out.print("\tadd x0, {s}, #8\n", .{src});
                            try out.appendSlice("\tbl _puts\n");
                        },
                        else => return error.TypeNotImpl,
                    }
                },
                .compare => |c| {
                    const lhs = try regFor(c.lhs, colors);
                    const rhs = try regFor(c.rhs, colors);
                    const dst = try regFor(c.dst, colors);
                    try out.print("\tcmp {s}, {s}\n", .{ lhs, rhs });
                    try out.print("\tcset {s}, {s}\n", .{ dst, condForCmp(c.op) });
                },
                .binop => |binop| {
                    const dst = try regFor(binop.dst, colors);
                    const lhs = try regFor(binop.lhs, colors);
                    const rhs = try regFor(binop.rhs, colors);

                    switch (binop.op) {
                        .add => try out.print("\tadd {s}, {s}, {s}\n", .{ dst, lhs, rhs }),
                        else => return error.NotSupported,
                    }
                },
                .branch => |b| {
                    const cond = try regFor(b.condition, colors);
                    try out.print("\tcmp {s}, #0\n", .{cond});
                    try out.print("\tb.ne _{s}_L{d}\n", .{ function.name, b.then_block });
                    try out.print("\tb _{s}_L{d}\n", .{ function.name, b.else_block });
                },
                .jump => |j| {
                    try out.print("\tb _{s}_L{d}\n", .{ function.name, j.target });
                },
                // x29 - 8  local: items pointer
                // x29 - 16 array[2]
                // x29 - 24 array[1]
                // x29 - 32 array[0]  <- array_base
                .array_literal => |al| {
                    const base_slot = next_array_slot;
                    next_array_slot += al.elements.len;

                    const dst = try regFor(al.dst, colors);

                    // array[i] = x29 - end + adjust(i)
                    for (al.elements, 0..al.elements.len) |elem, i| {
                        const src = try regFor(elem, colors);
                        const slot = base_slot + (al.elements.len - 1 - i);
                        const offset = arrayOffset(local_count, slot);
                        // HACK: assume everything is 8bytes wide
                        try out.print("\tstr {s}, [x29, #-{d}]\n", .{ src, offset });
                    }
                    // array_base = x29 - end
                    try out.print("\tsub {s}, x29, #{d}\n", .{ dst, arrayOffset(local_count, base_slot + al.elements.len - 1) });
                },
                // heap: [ size ] [elem 0] [...]
                .list_literal => |ll| {
                    const dst = try regFor(ll.dst, colors);
                    const elem_type = try getElementType(ll.type);
                    const elem_size = try sizeOfType(elem_type);
                    const byte_count = ll.elements.len * elem_size + 8;
                    const len = ll.elements.len;
                    try out.print("\tmov {s}, #{d}\n", .{ FirstParamRegister, byte_count });
                    try out.appendSlice("\tbl _arena_malloc\n");

                    try out.print("\tmov {s}, #{d}\n", .{ ScratchReg, len });
                    try out.print("\tstr {s}, [{s}]\n", .{ ScratchReg, CalleReturnRegister });

                    for (ll.elements, 0..len) |element, i| {
                        const src = try regFor(element, colors);
                        const offset = i * elem_size + 8;
                        switch (elem_type) {
                            // pointers & ints are size 8
                            .int, .list, .array => {
                                try out.print("\tstr {s}, [{s}, #{d}]\n", .{ src, CalleReturnRegister, offset });
                            },
                            .bool, .char => {
                                try out.print("\tstrb w{s}, [{s}, #{d}]\n", .{ src[1..], CalleReturnRegister, offset });
                            },
                            else => return error.TypeNotImpl,
                        }
                    }
                    try out.print("\tmov {s}, x0\n", .{dst});
                },
                .array_load => |al| {
                    const dst = try regFor(al.dst, colors);
                    const index = try regFor(al.index, colors);
                    const array = try regFor(al.array, colors);

                    const elem_type = try getElementType(al.type);
                    switch (elem_type) {
                        // index = index << 3
                        .int => {
                            try out.print("\tlsl {s}, {s}, #3\n", .{ index, index });
                            try out.print("\tldr {s}, [{s}, {s}]\n", .{ dst, array, index });
                        },
                        .bool => {
                            try out.print("\tldr w{s}, [{s}, {s}]\n", .{ dst[1..], array, index });
                        },
                        else => return error.TypeNotImpl,
                    }
                },
                .list_load => |ll| {
                    const dst = try regFor(ll.dst, colors);
                    const index = try regFor(ll.index, colors);
                    const array = try regFor(ll.list, colors);

                    const elem_type = try getElementType(ll.type);
                    switch (elem_type) {
                        // index = (index + 1) << 3
                        .int, .list, .array => {
                            try out.print("\tlsl {s}, {s}, #3\n", .{ ScratchReg, index });
                            try out.print("\tadd {s}, {s}, #8\n", .{ ScratchReg, ScratchReg });
                            try out.print("\tldr {s}, [{s}, {s}]\n", .{ dst, array, ScratchReg });
                        },
                        .bool, .char => {
                            try out.print("\tadd {s}, {s}, #8\n", .{ ScratchReg, index });
                            try out.print("\tldrb w{s}, [{s}, {s}]\n", .{ dst[1..], array, ScratchReg });
                        },
                        else => return error.TypeNotImpl,
                    }
                },
                .function_call => |fc| {
                    for (fc.args, 0..) |arg, i| {
                        const dst = try paramRegFor(i);
                        const src = try regFor(arg, colors);
                        try out.print("\tmov {s}, {s}\n", .{ dst, src });
                    }

                    try out.print("\tbl _{s}\n", .{fc.function_name});

                    if (fc.dst) |dst_op| {
                        const dst = try regFor(dst_op, colors);
                        try out.print("\tmov {s}, x0\n", .{dst});
                    }
                },
                .function_param => |fp| {
                    const dst = try regFor(fp.dst.operand, colors);
                    const src = try paramRegFor(fp.index);
                    try out.print("\tmov {s}, {s}\n", .{ dst, src });
                },
                .function_return => |fr| {
                    if (fr.value) |src_op| {
                        const src = try regFor(src_op, colors);
                        try out.print("\tmov x0, {s}\n", .{src});
                    }
                    try out.print("\tb _{s}_epilogue\n", .{function.name});
                },
                else => |ir| {
                    std.debug.panic("ir instruction doesnt have a mapping in arm backend: {s}\n", .{@tagName(ir)});
                    return error.NotSupported;
                },
            }
        }
    }
    try createFunctionFooter(out, function.name, local_stack_size, is_main);
}

fn createProgramHeader(out: *ArrayList(u8)) !void {
    try out.appendSlice(".section __TEXT,__text\n");
    try out.appendSlice(".global _main\n");
}

fn createFunctionHeader(out: *ArrayList(u8), name: []const u8, local_stack_size: usize) !void {
    try out.print("_{s}:\n", .{name});
    try out.appendSlice("\tstp x29, x30, [sp, #-16]!\n");
    try out.appendSlice("\tmov x29, sp\n");
    if (local_stack_size > 0) {
        try out.print("\tsub sp, sp, #{d}\n", .{local_stack_size});
    }
    try saveCallleSafeReg(out);
}

fn saveCallleSafeReg(out: *ArrayList(u8)) !void {
    std.debug.assert(CalleeSafeRegisters.len % 2 == 0);
    var i: usize = 0;
    while (i < CalleeSafeRegisters.len) : (i += 2) {
        const reg1 = CalleeSafeRegisters[i];
        const reg2 = CalleeSafeRegisters[i + 1];
        try out.print("\tstp {s}, {s}, [sp, #-16]!\n", .{ reg1, reg2 });
    }
}

fn restoreCallleSafeReg(out: *ArrayList(u8)) !void {
    std.debug.assert(CalleeSafeRegisters.len % 2 == 0);
    var i: usize = CalleeSafeRegisters.len;
    while (i > 0) {
        i -= 2;
        const reg1 = CalleeSafeRegisters[i];
        const reg2 = CalleeSafeRegisters[i + 1];
        try out.print("\tldp {s}, {s}, [sp], #16\n", .{ reg1, reg2 });
    }
}

fn createFunctionFooter(out: *ArrayList(u8), name: []const u8, local_stack_size: usize, is_main: bool) !void {
    try out.print("_{s}_epilogue:\n", .{name});
    if (is_main) {
        try out.appendSlice("\tbl _arena_free\n");
        try out.appendSlice("\tmov w0, #0\n");
    }

    try restoreCallleSafeReg(out);
    if (local_stack_size > 0) {
        try out.print("\tadd sp, sp, #{d}\n", .{local_stack_size});
    }

    // restore frame pointer and return address
    try out.appendSlice("\tldp x29, x30, [sp], #16\n");
    try out.appendSlice("\tret\n");
}

fn createFooter(out: *ArrayList(u8)) !void {
    try out.appendSlice("\n.section __TEXT,__cstring\n");
    try out.appendSlice("fmt:\n");
    try out.appendSlice("\t.asciz \"%ld\\n\"\n");
}

fn countLocals(blocks: *const ArrayList(Block)) usize {
    var max_local: ?common.ir.LocalId = null;
    for (blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .store_local => |sl| {
                    max_local = if (max_local) |m| @max(m, sl.local.id) else sl.local.id;
                },
                .load_local => |ll| {
                    max_local = if (max_local) |m| @max(m, ll.local.id) else ll.local.id;
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
                .array_literal => |al| slots += al.elements.len,
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

pub fn main() void {}

test "testing" {}
