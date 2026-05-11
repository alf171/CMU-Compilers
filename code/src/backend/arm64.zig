const std = @import("std");
const ArrayList = std.array_list.Managed;

const common = @import("common");
const color = @import("middle").color;
const regFor = @import("reg.zig").regFor;

pub fn emit(program: *const common.ir.Program, colors: *const color.ColoredGraph, alloc: std.mem.Allocator) ![]u8 {
    var out = ArrayList(u8).init(alloc);
    errdefer out.deinit();

    try createHeader(&out);

    var locals = std.AutoHashMap(common.ir.LocalId, common.alloc.Operand).init(alloc);
    defer locals.deinit();

    for (program.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .constant => |c| {
                    const dst = try regFor(c.dst, colors);
                    try out.print("\tmov {s}, #{d}\n", .{ dst, c.value });
                },
                .store_local => |sl| {
                    try locals.put(sl.local, sl.src);
                },
                .load_local => |ll| {
                    const src_op = locals.get(ll.local) orelse return error.LocalNotFound;
                    const dst = try regFor(ll.dst, colors);
                    const src = try regFor(src_op, colors);
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
                else => {
                    return error.NotSupported;
                },
            }
        }
    }
    try createFooter(&out);

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
pub fn createHeader(out: *ArrayList(u8)) !void {
    try out.appendSlice(".section __TEXT,__text\n");
    try out.appendSlice(".global _main\n");
    try out.appendSlice("_main:\n");
    try out.appendSlice("\tstp x29, x30, [sp, #-16]!\n");
    try out.appendSlice("\tmov x29, sp\n");
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
pub fn createFooter(out: *ArrayList(u8)) !void {
    try out.appendSlice("\tmov w0, #0\n");
    try out.appendSlice("\tldp x29, x30, [sp], #16\n");
    try out.appendSlice("\tret\n");
    try out.appendSlice("\n.section __TEXT,__cstring\n");
    try out.appendSlice("fmt:\n");
    try out.appendSlice("\t.asciz \"%ld\\n\"\n");
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
