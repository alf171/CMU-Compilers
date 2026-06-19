const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const LiteralElement = @import("common").ir.LiteralElement;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
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
        var new_instructions = ArrayList(Instruction).empty;
        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .print => |p| {
                    switch (p.src.type) {
                        .list => |l| {
                            if (l.element.* != .char) {
                                try new_instructions.append(alloc, instruction.*);
                                continue;
                            }
                            try new_instructions.append(alloc, .{ .lir = .{ .function_call = .{
                                .dst = null,
                                .function_name = "print_string",
                                .args = try alloc.dupe(TypedOperand, &.{p.src}),
                            } } });
                        },
                        .bool => {
                            try new_instructions.append(alloc, .{ .lir = .{ .function_call = .{
                                .dst = null,
                                .function_name = "print_bool",
                                .args = try alloc.dupe(TypedOperand, &.{p.src}),
                            } } });
                        },
                        .int => {
                            try new_instructions.append(alloc, .{ .lir = .{ .function_call = .{
                                .dst = null,
                                .function_name = "print_int",
                                .args = try alloc.dupe(TypedOperand, &.{p.src}),
                            } } });
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
