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
// .global _main
// _main:
//     stp x29, x30, [sp, #-16]!
//     mov x29, sp
pub fn createHeader(out: *ArrayList(u8)) !void {
    try out.appendSlice(".section __TEXT,__text\n");
    try out.appendSlice(".global _main\n");
    try out.appendSlice("_main:\n");
    try out.appendSlice("\tstp x29, x30, [sp, #-16]!\n");
    try out.appendSlice("\tmov x29, sp\n");
}

// TODO
pub fn createFooter(out: *ArrayList(u8)) !void {
    try out.appendSlice("\tmov w0, #0\n");
    try out.appendSlice("\tldp x29, x30, [sp], #16\n");
    try out.appendSlice("\tret\n");
    try out.appendSlice("\n.section __TEXT,__cstring\n");
    try out.appendSlice("fmt:\n");
    try out.appendSlice("\t.asciz \"%ld\\n\"\n");
}

pub fn main() void {}

test "testing" {}
