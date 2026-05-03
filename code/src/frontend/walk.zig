const std = @import("std");
const c = @import("python.zig").c;
const Program = @import("program.zig").Program;
const Operand = @import("program.zig").Operand;
const Instruction = @import("program.zig").Instruction;
const BinOp = @import("program.zig").BinOp;
const IrBuilder = @import("program.zig").IrBuilder;

const PyObject = c.PyObject;

const StmtKind = enum {
    Assign,
    Expr,
    Unknown
};

const ExprKind = enum {
    BinOp,
    Constant,
    // TODO: Name
    Unknown
};

pub fn walkAst(obj: ?*c.PyObject, alloc: std.mem.Allocator) !Program {
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    errdefer irBuilder.program.deinit();
    if (obj == null) return irBuilder.program;

    const body = c.PyObject_GetAttrString(obj, "body");
    std.debug.assert(body != null);
    const n = c.PyList_Size(body);

    var i: isize = 0;
    while (i < n) : (i += 1) {
        const raw_stmt = c.PyList_GetItem(body, i);
        const stmt = getStmtKind(raw_stmt);
        switch (stmt) {
            .Assign => try walkAssignment(raw_stmt, &irBuilder, alloc),
            .Expr => {
                const value = c.PyObject_GetAttrString(raw_stmt, "value");
                _ = try walkExpr(value, &irBuilder);
            },
            .Unknown => {
                std.debug.panic("unkown statement: {*}", .{raw_stmt});
            }
        }
    }

    return irBuilder.program;
}

// x = y = 1
// targets = [Name(id="x"), Name(id="y")]
// value = Constant(1)
fn walkAssignment(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) !void {
    const targets = c.PyObject_GetAttrString(stmt, "targets");
    std.debug.assert(targets != null);

    const lhs = c.PyList_GetItem(targets, 0);
    std.debug.assert(lhs != null);

    const id_obj = c.PyObject_GetAttrString(lhs, "id");
    const id = c.PyUnicode_AsUTF8(id_obj);

    const rhs = c.PyObject_GetAttrString(stmt, "value");
    const rhs_value = try walkExpr(rhs, irBuilder);

    const local = try irBuilder.getOrCreateLocal(std.mem.span(id), alloc);
    try irBuilder.emit(Instruction{
        .store_local = .{ .local = local, .src = rhs_value }
    });
}

fn walkExpr(stmt: *PyObject, irBuilder: *IrBuilder) !Operand {
    switch (getExprKind(stmt)) {
        .BinOp => {
            const left = c.PyObject_GetAttrString(stmt, "left");
            const right = c.PyObject_GetAttrString(stmt, "right");

            const op = try getBinOp(stmt);
            // order here will impact temp numbering
            const lhs = try walkExpr(left, irBuilder);
            const rhs = try walkExpr(right, irBuilder);
            const dst = irBuilder.nextTemp();

            const instruction = Instruction{.binop = .{
                .dst = dst,
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            }};
            try irBuilder.emit(instruction);
            return dst;
        },
        .Constant => {
            const value_obj = c.PyObject_GetAttrString(stmt, "value");
            const value = c.PyLong_AS_LONG(value_obj);

            const dst = irBuilder.nextTemp();
            try irBuilder.emit(Instruction{.constant = .{ .dst = dst, .value = value }});
            return dst;
        },
        .Unknown => {
            const name = getPyType(stmt);
            std.debug.print("unsupported expr type: {s}: ", .{name});
            printAstDump(stmt);
            return error.ExprUnknown;
        }
    }
}

fn getBinOp(expr: *PyObject) !BinOp {
    const op_obj = c.PyObject_GetAttrString(expr, "op");
    const name = getPyType(op_obj);

    if (std.mem.eql(u8, name, "Add")) return .add;
    if (std.mem.eql(u8, name, "Sub")) return .sub;
    if (std.mem.eql(u8, name, "Mult")) return .mul;
    if (std.mem.eql(u8, name, "Div")) return .div;

    std.debug.panic("unsupported binop: {s}", .{name});
    return error.NotFound;
}

fn getStmtKind(stmt: *PyObject) StmtKind {
    const name = getPyType(stmt);

    if (std.mem.eql(u8, name, "Assign")) return .Assign;
    if (std.mem.eql(u8, name, "Expr")) return .Expr;
    return .Unknown;
}

fn getExprKind(stmt: *PyObject) ExprKind {
    const name = getPyType(stmt);
    if (std.mem.eql(u8, name, "BinOp")) return .BinOp;
    if (std.mem.eql(u8, name, "Constant")) return .Constant;

    return .Unknown;
}

fn getPyType(stmt: *PyObject) []const u8 {
    const _type = c.PyObject_Type(stmt);
    const name_ptr = c.PyObject_GetAttrString(_type, "__name__");
    return std.mem.span(c.PyUnicode_AsUTF8(name_ptr));
}

fn printAstDump(node: *PyObject) void {
    const ast_module = c.PyImport_ImportModule("ast");
    std.debug.assert(ast_module != null);

    const dump_fn = c.PyObject_GetAttrString(ast_module, "dump");
    std.debug.assert(dump_fn != null);

    const dumped_obj = c.PyObject_CallFunction(dump_fn, "O", node);
    std.debug.assert(dumped_obj != null);

    const dumped = c.PyUnicode_AsUTF8(dumped_obj);
    std.debug.assert(dumped != null);

    std.debug.print("{s}\n", .{dumped});
}
