const std = @import("std");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const color = @import("middle").color;
const regFor = @import("reg.zig").regFor;
const CalleeSafeRegisters = @import("reg.zig").callee_safe_regs;

pub fn emit(program: *const common.ir.Program, colors: *const color.ColoredGraph, alloc: std.mem.Allocator) ![]u8 {
    var out = ArrayList(u8).init(alloc);
    errdefer out.deinit();

    const local_count = countLocals(program);
    const local_stack_size = std.mem.alignForward(usize, local_count * 8, 16);

    try createHeader(&out, local_stack_size);

    var strings = ArrayList([]const u8).init(alloc);
    var string_count: usize = 0;
    defer strings.deinit();

    for (program.blocks.items) |block| {
        try out.print("L{d}:\n", .{block.id});
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
                .print_int => |pi| {
                    const src = try regFor(pi.src, colors);
                    try out.appendSlice("\tsub sp, sp, #16\n");
                    try out.print("\tstr {s}, [sp]\n", .{src});
                    try out.appendSlice("\tadrp x0, fmt@PAGE\n");
                    try out.appendSlice("\tadd x0, x0, fmt@PAGEOFF\n");
                    try out.appendSlice("\tbl _printf\n");
                    try out.appendSlice("\tadd sp, sp, #16\n");
                },
                .print_string => |p| {
                    const label_id = string_count;
                    string_count += 1;
                    try strings.append(p.src);

                    try out.print("\tadrp x0, str{d}@PAGE\n", .{label_id});
                    try out.print("\tadd x0, x0, str{d}@PAGEOFF\n", .{label_id});
                    try out.appendSlice("\tbl _puts\n");
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
                    try out.print("\tb.ne L{d}\n", .{b.then_block});
                    try out.print("\tb L{d}\n", .{b.else_block});
                },
                .jump => |j| {
                    try out.print("\tb L{d}\n", .{j.target});
                },
                else => {
                    return error.NotSupported;
                },
            }
        }
    }
    try createFooter(&out, strings.items, local_stack_size);

    return out.toOwnedSlice();
}

// .section __TEXT,__text
//   Switch to the Mach-O executable code section. All following instructions
//   are emitted as program code until another section is selected.
// .global _main
//   Export the _main symbol so the linker can use it as the program entry
//   point. On macOS, C symbols use a leading underscore, so main becomes _main.
// _main:
//   Define the _main label. Execution starts here when the program runs.
// stp x29, x30, [sp, #-16]!
//   Allocate 16 bytes on the stack, then store x29 and x30 there.
//   x29 is the frame pointer. x30 is the link register / return address.
//   The ! means pre-indexed addressing: update sp first, then store.
// mov x29, sp
//   Set this function's frame pointer to the current stack pointer.
// sub sp, sp, #local_stack_size
//   offset my number of local variables
pub fn createHeader(out: *ArrayList(u8), local_stack_size: usize) !void {
    try out.appendSlice(".section __TEXT,__text\n");
    try out.appendSlice(".global _main\n");
    try out.appendSlice("_main:\n");
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

// mov w0, #0
//   Return 0 from main. On ARM64, integer return values are placed in w0.
// ldp x29, x30, [sp], #16
//   Restore the caller's frame pointer (x29) and return address (x30)
//   from the stack, then move sp back up by 16 bytes.
// ret
//   Return to the caller by jumping to the address in x30.
// .section __TEXT,__cstring
//   Switch from the executable code section to the Mach-O C string section.
// fmt:
//   Define the label used by print_int code to find the printf format string.
// .asciz "%ld\n"
//   Emit a null-terminated C string for printf: print a 64-bit integer,
//   followed by a newline.
fn createFooter(out: *ArrayList(u8), strings: []const []const u8, local_stack_size: usize) !void {
    try out.appendSlice("\tmov w0, #0\n");

    try restoreCallleSafeReg(out);
    if (local_stack_size > 0) {
        try out.print("\tadd sp, sp, #{d}\n", .{local_stack_size});
    }

    // restore frame pointer and return address
    try out.appendSlice("\tldp x29, x30, [sp], #16\n");
    try out.appendSlice("\tret\n");
    try out.appendSlice("\n.section __TEXT,__cstring\n");
    try out.appendSlice("fmt:\n");
    try out.appendSlice("\t.asciz \"%ld\\n\"\n");

    for (strings, 0..) |s, i| {
        try out.print("str{d}:\n", .{i});
        try out.print("\t.asciz \"{s}\"\n", .{s});
    }
}

fn countLocals(program: *const common.ir.Program) usize {
    var max_local: ?common.ir.LocalId = null;
    for (program.blocks.items) |block| {
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

fn localOffset(local: common.ir.LocalId) usize {
    return (@as(usize, local) + 1) * 8;
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
