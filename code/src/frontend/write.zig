const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
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
                    // init fd
                    const fd = function.nextTemp();
                    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                        .dst = fd,
                        .value = .{ .int = 1 },
                    } } });
                    const one = function.nextTemp();
                    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
                        .dst = one,
                        .value = .{ .int = 1 },
                    } } });
                    const eight = function.nextTemp();
                    try new_instructions.append(alloc, Instruction{
                        .lir = .{
                            .constant = .{ .dst = eight, .value = .{ .int = 8 } },
                        },
                    });
                    switch (p.src.type) {
                        .list => |l| {
                            if (l.element.* != .char) {
                                try new_instructions.append(alloc, instruction.*);
                                continue;
                            }
                            try printString(function, &new_instructions, p.src, fd, one, eight, alloc);
                            try printNewLine(function, &new_instructions, one, eight, fd, alloc);
                        },
                        .bool => {
                            try printBool(function, &new_instructions, p.src.operand, one, eight, alloc);
                        },
                        // TODO: impl
                        .int => {
                            try new_instructions.append(alloc, instruction.*);
                            continue;
                        },
                        else => {
                            try new_instructions.append(alloc, instruction.*);
                            continue;
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

fn printString(
    function: *Function,
    new_instructions: *ArrayList(Instruction),
    print_target: TypedOperand,
    fd: Operand,
    one: Operand,
    eight: Operand,
    alloc: std.mem.Allocator,
) !void {
    // init len
    const raw_len = function.nextTemp();
    try new_instructions.append(alloc, .{ .len = .{
        .dst = raw_len,
        .value = print_target,
    } });
    // strip \0
    const len = function.nextTemp();
    try new_instructions.append(alloc, .{ .lir = .{ .binop = .{
        .dst = len,
        .lhs = raw_len,
        .op = .sub,
        .rhs = one,
    } } });

    // increment by 8
    const buf = function.nextTemp();
    try new_instructions.append(alloc, Instruction{ .lir = .{ .binop = .{
        .dst = buf,
        .lhs = print_target.operand,
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
                    .type = print_target.type,
                },
                .len = len,
            },
        },
    });
}

fn printBool(
    function: *Function,
    new_instructions: *ArrayList(Instruction),
    condition_operand: Operand,
    one: Operand,
    eight: Operand,
    alloc: std.mem.Allocator,
) !void {
    const true_str = "True\n";
    const true_raw = try emitCharList(function, new_instructions, true_str, alloc);
    const true_op = function.nextTemp();
    try new_instructions.append(alloc, .{
        .lir = .{ .binop = .{
            .dst = true_op,
            .lhs = true_raw.operand,
            .op = .add,
            .rhs = eight,
        } },
    });
    const false_str = "False\n";
    const false_raw = try emitCharList(function, new_instructions, false_str, alloc);
    const false_op = function.nextTemp();
    try new_instructions.append(alloc, .{
        .lir = .{ .binop = .{
            .dst = false_op,
            .lhs = false_raw.operand,
            .op = .add,
            .rhs = eight,
        } },
    });
    const dst = function.nextTemp();
    // buf
    try new_instructions.append(alloc, .{ .lir = .{ .select = .{
        .dst = dst,
        .condition = condition_operand,
        .if_value = true_op,
        .else_value = false_op,
    } } });
    // len
    const true_len = function.nextTemp();
    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
        .dst = true_len,
        .value = .{ .int = true_str.len },
    } } });
    const false_len = function.nextTemp();
    try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
        .dst = false_len,
        .value = .{ .int = false_str.len },
    } } });
    const len = function.nextTemp();
    try new_instructions.append(alloc, .{ .lir = .{ .select = .{
        .dst = len,
        .condition = condition_operand,
        .if_value = true_len,
        .else_value = false_len,
    } } });
    try new_instructions.append(alloc, .{ .lir = .{ .write = .{
        .fd = one,
        .buf = .{ .operand = dst, .type = .{ .list = .{
            .element = try ownedPointer(.char, alloc),
            .size = null,
        } } },
        .len = len,
    } } });
}

fn emitCharList(
    function: *Function,
    new_instructions: *ArrayList(Instruction),
    chars: []const u8,
    alloc: std.mem.Allocator,
) !TypedOperand {
    var operands = try alloc.alloc(Operand, chars.len);
    for (chars, 0..) |char, i| {
        const c = function.nextTemp();
        try new_instructions.append(alloc, .{ .lir = .{ .constant = .{
            .dst = c,
            .value = .{ .char = char },
        } } });
        operands[i] = c;
    }
    const list = function.nextTemp();
    try new_instructions.append(alloc, .{ .lir = .{ .list_literal = .{
        .dst = .{
            .operand = list,
            .type = .{ .list = .{
                .element = try ownedPointer(.char, alloc),
                .size = chars.len,
            } },
        },
        .elements = operands,
    } } });

    return .{
        .operand = list,
        .type = .{ .list = .{
            .element = try ownedPointer(.char, alloc),
            .size = chars.len,
        } },
    };
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
