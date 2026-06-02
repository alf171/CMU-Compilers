const std = @import("std");
const c = @import("python.zig").c;
const walkAst = @import("walk.zig").walkAst;

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

    var program = try walkAst(tree, alloc);
    defer program.deinit(alloc);
    try program.print();
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

    var program = try walkAst(tree, alloc);
    defer program.deinit(alloc);
    try std.testing.expectEqual(program.main.blocks.items.len, 1);
    // block0:
    try std.testing.expectEqual(program.main.blocks.items[0].id, 0);
    const instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(instructions.len, 4);
    // temp0 <- const 1
    switch (instructions[0]) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.dst.temp);
            try std.testing.expect(instruction.value == .int);
            try std.testing.expectEqual(@as(i64, 1), instruction.value.int);
        },
        else => return error.ExpectedConstant,
    }
    // temp1 <- const 2
    switch (instructions[1]) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 1), instruction.dst.temp);
            try std.testing.expect(instruction.value == .int);
            try std.testing.expectEqual(@as(i64, 2), instruction.value.int);
        },
        else => return error.ExpectedConstant,
    }
    // temp2 <- add temp0, temp1
    switch (instructions[2]) {
        .binop => |instruction| {
            try std.testing.expectEqual(@as(u32, 2), instruction.dst.temp);
            try std.testing.expectEqual(.add, instruction.op);
            try std.testing.expectEqual(@as(u32, 0), instruction.lhs.temp);
            try std.testing.expectEqual(@as(u32, 1), instruction.rhs.temp);
        },
        else => return error.ExpectedBinop,
    }
    // local0 <- temp2
    switch (instructions[3]) {
        .store_local => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.local.id);
            try std.testing.expectEqual(@as(u32, 2), instruction.src.temp);
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

    var program = try walkAst(tree, alloc);
    defer program.deinit(alloc);
    try std.testing.expectEqual(program.main.blocks.items.len, 1);
    // block0:
    try std.testing.expectEqual(program.main.blocks.items[0].id, 0);
    const instructions = program.main.blocks.items[0].instructions.items;
    try std.testing.expectEqual(instructions.len, 4);
    // temp0 <- const True
    switch (instructions[0]) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.dst.temp);
            try std.testing.expect(instruction.value == .bool);
            try std.testing.expectEqual(true, instruction.value.bool);
        },
        else => return error.ExpectedConstant,
    }
    // temp1 <- const False
    switch (instructions[1]) {
        .constant => |instruction| {
            try std.testing.expectEqual(@as(u32, 1), instruction.dst.temp);
            try std.testing.expect(instruction.value == .bool);
            try std.testing.expectEqual(false, instruction.value.bool);
        },
        else => return error.ExpectedConstant,
    }
    // temp2 <- temp0 != temp1
    switch (instructions[2]) {
        .compare => |instruction| {
            try std.testing.expectEqual(@as(u32, 2), instruction.dst.temp);
            try std.testing.expectEqual(.neq, instruction.op);
            try std.testing.expectEqual(@as(u32, 0), instruction.lhs.temp);
            try std.testing.expectEqual(@as(u32, 1), instruction.rhs.temp);
        },
        else => return error.ExpectedBinop,
    }
    // local0 <- temp2
    switch (instructions[3]) {
        .store_local => |instruction| {
            try std.testing.expectEqual(@as(u32, 0), instruction.local.id);
            try std.testing.expectEqual(@as(u32, 2), instruction.src.temp);
        },
        else => return error.ExpectedBinop,
    }
}
