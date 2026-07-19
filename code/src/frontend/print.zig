const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const ValueRef = @import("common").ir.ValueRef;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const PrintInst = @import("common").mir.PrintInst;
const ownedPointer = @import("common").types.ownedPointer;

pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    try rewriteFunction(&program.main, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(function, alloc);
    }
}

/// rewrite function distructively
fn rewriteFunction(function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions: ArrayList(Instruction) = .empty;
        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .print => |p| {
                    const args = try alloc.alloc(TypedOperand, 1);
                    errdefer alloc.free(args);
                    args[0] = try p.src.clone(alloc);
                    switch (p.src.type) {
                        .list => |l| {
                            if (l.element.* == .char) {
                                try new_instructions.append(alloc, .{ .function_call = .{
                                    .dst = null,
                                    .callee = .{ .direct = try alloc.dupe(u8, "print_string") },
                                    .args = args,
                                } });
                            } else if (l.element.* == .i64 or l.element.* == .i32) {
                                try new_instructions.append(alloc, .{ .function_call = .{
                                    .dst = null,
                                    .callee = .{ .direct = try alloc.dupe(u8, "print_int_list") },
                                    .args = args,
                                } });
                            }
                        },
                        .bool => {
                            try new_instructions.append(alloc, .{ .function_call = .{
                                .dst = null,
                                .callee = .{ .direct = try alloc.dupe(u8, "print_bool") },
                                .args = args,
                            } });
                        },
                        .i64, .i32 => {
                            try new_instructions.append(alloc, .{ .function_call = .{
                                .dst = null,
                                .callee = .{ .direct = try alloc.dupe(u8, "print_int") },
                                .args = args,
                            } });
                        },
                        .float => {
                            try new_instructions.append(alloc, .{ .function_call = .{
                                .dst = null,
                                .callee = .{ .direct = try alloc.dupe(u8, "print_float") },
                                .args = args,
                            } });
                        },
                        else => |e| {
                            std.debug.print("dont support print of type {s}\n", .{@tagName(e)});
                            return error.UnsupportedPrint;
                        },
                    }
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}
