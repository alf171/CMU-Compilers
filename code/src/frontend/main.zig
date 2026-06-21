const std = @import("std");
const c = @import("python.zig").c;
const walkAstIntoBuilder = @import("walk.zig").walkAstIntoBuilder;
const IrBuilder = @import("builder.zig").IrBuilder;

pub fn main(init: std.process.Init) !void {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const alloc = init.gpa;
    const code: [*:0]const u8 =
        \\a = 5
        \\b = 10
        \\print(a + b)
    ;

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code);
    std.debug.assert(tree != null);

    var irBuilder = try IrBuilder.init(alloc);
    irBuilder.deinit(alloc);
    try walkAstIntoBuilder(tree, &irBuilder, alloc);
    defer irBuilder.program.deinit(alloc);
}

test "x = 1 + 2" {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const alloc = std.testing.allocator;
    const code: [*:0]const u8 = "x = 1 + 2";

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code);
    std.debug.assert(tree != null);

    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    try walkAstIntoBuilder(tree, &irBuilder, alloc);
    var program = irBuilder.program;
    defer program.deinit(alloc);

    try std.testing.expectEqual(program.main.blocks.items.len, 1);
    // block0:
    try std.testing.expectEqual(program.main.blocks.items[0].id, 0);
    const instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(instructions.len, 4);
    // temp0 <- const 1
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[0]));
    switch (instructions[0].lir) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.dst.temp.id);
            try std.testing.expect(instruction.value == .int);
            try std.testing.expectEqual(@as(i64, 1), instruction.value.int);
        },
        else => return error.ExpectedConstant,
    }
    // temp1 <- const 2
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[1]));
    switch (instructions[1].lir) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 1), instruction.dst.temp.id);
            try std.testing.expect(instruction.value == .int);
            try std.testing.expectEqual(@as(i64, 2), instruction.value.int);
        },
        else => return error.ExpectedConstant,
    }
    // temp2 <- add temp0, temp1
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[2]));
    switch (instructions[2].lir) {
        .binop => |instruction| {
            try std.testing.expectEqual(@as(u32, 2), instruction.dst.temp.id);
            try std.testing.expectEqual(.add, instruction.op);
            try std.testing.expectEqual(@as(u32, 0), instruction.lhs.temp.id);
            try std.testing.expectEqual(@as(u32, 1), instruction.rhs.temp.id);
        },
        else => return error.ExpectedBinop,
    }
    // local0 <- temp2
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[3]));
    switch (instructions[3].lir) {
        .store_local => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.local.id);
            try std.testing.expectEqual(@as(u32, 2), instruction.src.temp.id);
        },
        else => return error.ExpectedBinop,
    }
}

test "x = true != false" {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const alloc = std.testing.allocator;
    const code: [*:0]const u8 = "x = True != False";

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code);
    std.debug.assert(tree != null);

    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    try walkAstIntoBuilder(tree, &irBuilder, alloc);
    var program = irBuilder.program;
    defer program.deinit(alloc);

    try std.testing.expectEqual(program.main.blocks.items.len, 1);
    // block0:
    try std.testing.expectEqual(program.main.blocks.items[0].id, 0);
    const instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(instructions.len, 4);
    // temp0 <- const True
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[0]));
    switch (instructions[0].lir) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.dst.temp.id);
            try std.testing.expect(instruction.value == .bool);
            try std.testing.expectEqual(true, instruction.value.bool);
        },
        else => return error.ExpectedConstant,
    }
    // temp1 <- const False
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[1]));
    switch (instructions[1].lir) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 1), instruction.dst.temp.id);
            try std.testing.expect(instruction.value == .bool);
            try std.testing.expectEqual(false, instruction.value.bool);
        },
        else => return error.ExpectedConstant,
    }
    // temp2 <- temp0 != temp1
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[2]));
    switch (instructions[2].lir) {
        .compare => |instruction| {
            try std.testing.expectEqual(@as(u32, 2), instruction.dst.temp.id);
            try std.testing.expectEqual(.neq, instruction.op);
            try std.testing.expectEqual(@as(u32, 0), instruction.lhs.temp.id);
            try std.testing.expectEqual(@as(u32, 1), instruction.rhs.temp.id);
        },
        else => return error.ExpectedBinop,
    }
    // local0 <- temp2
    try std.testing.expectEqual(.lir, std.meta.activeTag(instructions[3]));
    switch (instructions[3].lir) {
        .store_local => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.local.id);
            try std.testing.expectEqual(@as(u32, 2), instruction.src.temp.id);
        },
        else => return error.ExpectedBinop,
    }
}
