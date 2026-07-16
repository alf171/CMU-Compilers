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
                    switch (p.src.type) {
                        .list => |l| {
                            if (l.element.* == .char) {
                                const new_line: TypedOperand = .{
                                    .operand = function.nextTemp(),
                                    .type = .bool,
                                };
                                try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                    .dst = new_line,
                                    .src = .{ .constant = .{ .bool = true } },
                                } } });
                                try new_instructions.append(alloc, .{ .function_call = .{
                                    .dst = null,
                                    .callee = .{ .direct = "print_string" },
                                    .args = try alloc.dupe(TypedOperand, &.{ p.src, new_line }),
                                } });
                            } else if (l.element.* == .i64 or l.element.* == .i32) {
                                try new_instructions.append(alloc, .{ .function_call = .{
                                    .dst = null,
                                    .callee = .{ .direct = "print_int_list" },
                                    .args = try alloc.dupe(TypedOperand, &.{p.src}),
                                } });
                            }
                        },
                        .bool => {
                            try new_instructions.append(alloc, .{ .function_call = .{
                                .dst = null,
                                .callee = .{ .direct = "print_bool" },
                                .args = try alloc.dupe(TypedOperand, &.{p.src}),
                            } });
                        },
                        .i64, .i32 => {
                            const new_line: TypedOperand = .{
                                .operand = function.nextTemp(),
                                .type = .bool,
                            };
                            try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                                .dst = new_line,
                                .src = .{ .constant = .{ .bool = true } },
                            } } });
                            try new_instructions.append(alloc, .{ .function_call = .{
                                .dst = null,
                                .callee = .{ .direct = "print_int" },
                                .args = try alloc.dupe(TypedOperand, &.{ p.src, new_line }),
                            } });
                        },
                        .float => {
                            try new_instructions.append(alloc, .{ .function_call = .{
                                .dst = null,
                                .callee = .{ .direct = "print_float" },
                                .args = try alloc.dupe(TypedOperand, &.{p.src}),
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
