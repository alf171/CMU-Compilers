const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Operand = @import("common").alloc.Operand;
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
                        },
                        else => {
                            try new_instructions.append(alloc, instruction.*);
                            continue;
                        },
                    }
                    // init fd
                    const fd = function.nextTemp();
                    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                        .dst = fd,
                        .value = .{ .int = 1 },
                    } } });
                    // init len
                    const raw_len = function.nextTemp();
                    try new_instructions.append(alloc, .{ .len = .{
                        .dst = raw_len,
                        .value = p.src,
                    } });
                    // strip \0
                    const one = function.nextTemp();
                    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                        .dst = one,
                        .value = .{ .int = 1 },
                    } } });
                    const len = function.nextTemp();
                    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
                        .dst = len,
                        .lhs = raw_len,
                        .op = .sub,
                        .rhs = one,
                    } } });

                    // increment by 8
                    const eight = function.nextTemp();
                    try new_instructions.append(alloc, Instruction{
                        .lir = .{
                            .constant = .{ .dst = eight, .value = .{ .int = 8 } },
                        },
                    });
                    const buf = function.nextTemp();
                    try new_instructions.append(alloc, Instruction{ .lir = .{ .binop = .{
                        .dst = buf,
                        .lhs = p.src.operand,
                        .op = .add,
                        .rhs = eight,
                    } } });
                    // crux
                    try new_instructions.append(alloc, Instruction{
                        .lir = .{
                            .write = .{
                                .fd = fd,
                                .buf = .{
                                    .operand = buf,
                                    .type = p.src.type,
                                },
                                .len = len,
                            },
                        },
                    });
                    try printNewLine(function, &new_instructions, one, eight, fd, alloc);
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

fn printNewLine(
    function: *Function,
    new_instructions: *ArrayList(Instruction),
    one: Operand,
    eight: Operand,
    fd: Operand,
    alloc: std.mem.Allocator,
) !void {
    // addition write call to append \n
    const new_line_literal = function.nextTemp();
    try new_instructions.append(alloc, Instruction{ .lir = .{ .constant = .{ .dst = new_line_literal, .value = .{
        .char = '\n',
    } } } });
    const new_line_buf_raw = function.nextTemp();
    // list literal
    try new_instructions.append(alloc, Instruction{ .lir = .{ .list_literal = .{
        .dst = .{ .operand = new_line_buf_raw, .type = .{
            .list = .{
                .element = try ownedPointer(.char, alloc),
                .size = 1,
            },
        } },
        .elements = try alloc.dupe(Operand, &.{new_line_literal}),
    } } });
    // += 8
    const new_line_buf = function.nextTemp();
    try new_instructions.append(alloc, Instruction{ .lir = .{ .binop = .{
        .dst = new_line_buf,
        .lhs = new_line_buf_raw,
        .op = .add,
        .rhs = eight,
    } } });
    try new_instructions.append(alloc, Instruction{
        .lir = .{
            .write = .{
                .fd = fd,
                .buf = .{
                    .operand = new_line_buf,
                    .type = .{ .list = .{
                        .element = try ownedPointer(.char, alloc),
                        .size = 1,
                    } },
                },
                .len = one,
            },
        },
    });
}
