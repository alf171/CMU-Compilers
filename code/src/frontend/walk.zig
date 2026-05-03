const std = @import("std");
const c = @import("python.zig").c;
const Program = @import("program.zig").Program;
const Operand = @import("program.zig").Operand;
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
    Unknown
};

pub fn walkAst(obj: ?*c.PyObject, alloc: std.mem.Allocator) Program {
    const irBuilder = IrBuilder.init(alloc);
    _ = irBuilder;
    if (obj == null) return;

    const body = c.PyObject_GetAttrString(obj, "body");
    std.debug.assert(body != null);
    const n = c.PyList_Size(body);

    var i: isize = 0;
    while (i < n) : (i += 1) {
        const raw_stmt = c.PyList_GetItem(body, i);
        const stmt = getStmtKind(raw_stmt);
        switch (stmt) {
            .Assign => walkAssignment(raw_stmt),
            .Expr => {
                const value = c.PyObject_GetAttrString(raw_stmt, "value");
                walkExpr(value);
            },
            .Unknown => {
                std.debug.panic("unkown statement: {*}", .{raw_stmt});
            }
        }
    }
}

// x = y = 1
// targets = [Name(id="x"), Name(id="y")]
// value = Constant(1)
fn walkAssignment(stmt: *PyObject) void {
    const targets = c.PyObject_GetAttrString(stmt, "targets");
    std.debug.assert(targets != null);

    const lhs = c.PyList_GetItem(targets, 0);
    std.debug.assert(lhs != null);

    // const rhs = 
    const id_obj = c.PyObject_GetAttrString(lhs, "id");
    const id = c.PyUnicode_AsUTF8(id_obj);
    std.debug.print("assign lhs {s}\n", .{id});

    const rhs = c.PyObject_GetAttrString(stmt, "value");
    walkExpr(rhs);
}

fn walkExpr(stmt: *PyObject) void {
    switch (getExprKind(stmt)) {
        .BinOp => {
            std.debug.print("expr: BinOp!\n", .{});
            const left = c.PyObject_GetAttrString(stmt, "left");
            const right = c.PyObject_GetAttrString(stmt, "right");
            _ = walkExpr(left);
            _ = walkExpr(right);
        },
        .Constant => {
            std.debug.print("expr: constant\n", .{});
        },
        .Unknown => {}
    }
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

