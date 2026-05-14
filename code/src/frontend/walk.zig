const std = @import("std");
const c = @import("python.zig").c;

const Operand = @import("common").alloc.Operand;
const Instruction = @import("common").ir.Instruction;
const BinOp = @import("common").ir.BinOp;
const CmpOp = @import("common").ir.CmpOp;
const Program = @import("common").ir.Program;
const PhiInput = @import("common").ir.PhiInput;
const UnaryOp = @import("common").ir.UnaryOp;

const IrBuilder = @import("builder.zig").IrBuilder;

const PyObject = c.PyObject;

const StmtKind = enum { Assign, Expr, If, While, Unknown };

const ExprKind = enum { BinOp, UnaryOp, Compare, Constant, Name, Unknown, Call };

pub fn walkAst(obj: ?*c.PyObject, alloc: std.mem.Allocator) !Program {
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    errdefer irBuilder.program.deinit();
    if (obj == null) return irBuilder.program;

    const body = c.PyObject_GetAttrString(obj, "body");
    std.debug.assert(body != null);

    try walkStmtList(body, &irBuilder, alloc);

    return irBuilder.program;
}

pub fn walkStmtList(stmts: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    const n = c.PyList_Size(stmts);
    var i: isize = 0;

    while (i < n) : (i += 1) {
        const raw_stmt = c.PyList_GetItem(stmts, i);
        try walkStmt(raw_stmt, irBuilder, alloc);
    }
}

pub fn walkStmt(raw_stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    const stmt = getStmtKind(raw_stmt);
    switch (stmt) {
        .Assign => try walkAssignment(raw_stmt, irBuilder, alloc),
        .Expr => {
            const value = c.PyObject_GetAttrString(raw_stmt, "value");
            _ = try walkExpr(value, irBuilder, alloc);
        },
        .If => try walkIf(raw_stmt, irBuilder, alloc),
        .While => try walkWhile(raw_stmt, irBuilder, alloc),
        .Unknown => {
            std.debug.panic("unkown statement: {*}", .{raw_stmt});
        },
    }
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
    const rhs_value = try walkExpr(rhs, irBuilder, alloc);

    const local = try irBuilder.getOrCreateLocal(std.mem.span(id), alloc);
    try irBuilder.local_values.put(local, rhs_value);
    try irBuilder.emit(Instruction{ .store_local = .{ .local = local, .src = rhs_value } });
}

fn walkExpr(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) !Operand {
    switch (getExprKind(stmt)) {
        .BinOp => {
            const left = c.PyObject_GetAttrString(stmt, "left");
            const right = c.PyObject_GetAttrString(stmt, "right");

            const op = try getBinOp(stmt);
            // order here will impact temp numbering
            const lhs = try walkExpr(left, irBuilder, alloc);
            const rhs = try walkExpr(right, irBuilder, alloc);
            const dst = irBuilder.nextTemp();

            const instruction = Instruction{ .binop = .{
                .dst = dst,
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } };
            try irBuilder.emit(instruction);
            return dst;
        },
        .UnaryOp => {
            const operand_obj = c.PyObject_GetAttrString(stmt, "operand");
            const src = try walkExpr(operand_obj, irBuilder, alloc);
            const dst = irBuilder.nextTemp();
            const op = try getUnaryOp(stmt);
            try irBuilder.emit(Instruction{ .unaryop = .{ .dst = dst, .op = op, .src = src } });
            return dst;
        },
        .Constant => {
            const value_obj = c.PyObject_GetAttrString(stmt, "value");
            const value = c.PyLong_AsLong(value_obj);

            const dst = irBuilder.nextTemp();
            try irBuilder.emit(Instruction{ .constant = .{ .dst = dst, .value = value } });
            return dst;
        },
        .Name => {
            const id_obj = c.PyObject_GetAttrString(stmt, "id");
            std.debug.assert(id_obj != null);

            const id = c.PyUnicode_AsUTF8(id_obj);
            std.debug.assert(id != null);

            const local = try irBuilder.getOrCreateLocal(std.mem.span(id), alloc);

            if (irBuilder.local_values.get(local)) |value| {
                return value;
            }

            const dst = irBuilder.nextTemp();
            try irBuilder.emit(Instruction{ .load_local = .{ .dst = dst, .local = local } });
            return dst;
        },
        // Compare(left=Constant(1),ops=[Lt()],comparators=[Constant(2)])
        .Compare => {
            const left_obj = c.PyObject_GetAttrString(stmt, "left");
            const comparators = c.PyObject_GetAttrString(stmt, "comparators");
            std.debug.assert(left_obj != null);
            std.debug.assert(comparators != null);
            const right_obj = c.PyList_GetItem(comparators, 0);
            std.debug.assert(right_obj != null);

            const lhs = try walkExpr(left_obj, irBuilder, alloc);
            const rhs = try walkExpr(right_obj, irBuilder, alloc);
            const dst = irBuilder.nextTemp();
            const op = try getCompareOp(stmt);

            try irBuilder.emit(Instruction{ .compare = .{ .dst = dst, .lhs = lhs, .op = op, .rhs = rhs } });

            return dst;
        },
        // Expr(value=Call(func=Name(id="print"),args=[BinOp(...)]))
        .Call => {
            const func = c.PyObject_GetAttrString(stmt, "func");
            std.debug.assert(func != null);

            const func_id = c.PyObject_GetAttrString(func, "id");
            std.debug.assert(func_id != null);

            const name = c.PyUnicode_AsUTF8(func_id);
            std.debug.assert(name != null);

            if (!std.mem.eql(u8, std.mem.span(name), "print")) {
                return error.UnsupportedCall;
            }
            const args = c.PyObject_GetAttrString(stmt, "args");
            std.debug.assert(args != null);
            std.debug.assert(c.PyList_Size(args) == 1);
            const arg0 = c.PyList_GetItem(args, 0);
            std.debug.assert(arg0 != null);

            if (getExprKind(arg0) == .Constant) {
                const value_obj = c.PyObject_GetAttrString(arg0, "value");
                const value_type = getPyType(value_obj);

                if (std.mem.eql(u8, value_type, "str")) {
                    const raw = c.PyUnicode_AsUTF8(value_obj);
                    std.debug.assert(raw != null);

                    const owned = try alloc.dupe(u8, std.mem.span(raw));
                    try irBuilder.emit(Instruction{ .print_string = .{ .src = owned } });
                    // HACK: in order to support string printing
                    return Operand{ .temp = 0 };
                }
            }

            const src = try walkExpr(arg0, irBuilder, alloc);
            try irBuilder.emit(Instruction{ .print_int = .{ .src = src } });
            return src;
        },
        .Unknown => {
            const name = getPyType(stmt);
            std.debug.print("unsupported expr type: {s}: ", .{name});
            printAstDump(stmt);
            return error.ExprUnknown;
        },
    }
}

// If(test=Compare(...), body=[...], orelse=[...])
pub fn walkIf(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    var before_values = try irBuilder.cloneLocalValues(alloc);
    defer before_values.deinit();

    const test_ = c.PyObject_GetAttrString(stmt, "test");
    const body = c.PyObject_GetAttrString(stmt, "body");
    const orelse_ = c.PyObject_GetAttrString(stmt, "orelse");

    const then_block = try irBuilder.newBlock(alloc);
    const else_block = try irBuilder.newBlock(alloc);
    const merge_block = try irBuilder.newBlock(alloc);

    const condition = try walkExpr(test_, irBuilder, alloc);
    try irBuilder.emit(Instruction{
        .branch = .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
        },
    });
    try irBuilder.addSuccessor(irBuilder.current_block, then_block);
    try irBuilder.addSuccessor(irBuilder.current_block, else_block);

    // then block
    irBuilder.setCurrentBlock(then_block);
    // restore in case condition set variables
    try irBuilder.restoreLocalValues(&before_values);
    try walkStmtList(body, irBuilder, alloc);
    // save then locals
    var then_values = try irBuilder.cloneLocalValues(alloc);
    defer then_values.deinit();
    try irBuilder.emit(Instruction{
        .jump = .{ .target = merge_block },
    });
    try irBuilder.addSuccessor(then_block, merge_block);

    // else block
    irBuilder.setCurrentBlock(else_block);
    // restore in case condition set variables
    try irBuilder.restoreLocalValues(&before_values);
    try walkStmtList(orelse_, irBuilder, alloc);
    // save else locals
    var else_values = try irBuilder.cloneLocalValues(alloc);
    defer else_values.deinit();
    try irBuilder.emit(Instruction{
        .jump = .{ .target = merge_block },
    });
    try irBuilder.addSuccessor(else_block, merge_block);

    irBuilder.setCurrentBlock(merge_block);
    // Keep a variable's version only if:
    // 1. then branch has the same version as before
    // 2. else branch has the same version as before
    irBuilder.local_values.clearRetainingCapacity();
    var it = before_values.keyIterator();
    while (it.next()) |local| {
        const then_value = then_values.get(local.*);
        const else_value = else_values.get(local.*);
        // same value in both branches
        if (then_value != null and else_value != null and then_value.?.equal(else_value.?)) {
            try irBuilder.local_values.put(local.*, then_value.?);
        } else if (then_value != null and else_value != null) {
            const dst = irBuilder.nextTemp();
            const inputs = try alloc.dupe(PhiInput, &.{
                .{ .pred = then_block, .value = then_value.? },
                .{ .pred = else_block, .value = else_value.? },
            });

            try irBuilder.emit(Instruction{
                .phi = .{ .dst = dst, .inputs = inputs, .local = local.* },
            });
            try irBuilder.local_values.put(local.*, dst);
        } else {
            return error.NotImplemented;
        }
    }
}

// While(test=Compare(...), body=[...], orelse=[...])
// current:
//   jump cond
// cond:
//   condition
//   branch body exit
// body:
//   body statements
//   jump cond
// exit:
//   continue
pub fn walkWhile(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    const test_ = c.PyObject_GetAttrString(stmt, "test");
    const body = c.PyObject_GetAttrString(stmt, "body");
    const orelse_ = c.PyObject_GetAttrString(stmt, "orelse");
    std.debug.assert(test_ != null);
    std.debug.assert(body != null);
    std.debug.assert(orelse_ != null);

    const entry_block = irBuilder.current_block;
    const condition_block = try irBuilder.newBlock(alloc);
    const body_block = try irBuilder.newBlock(alloc);
    const exit_block = try irBuilder.newBlock(alloc);

    try irBuilder.emit(Instruction{ .jump = .{ .target = condition_block } });
    try irBuilder.addSuccessor(entry_block, condition_block);

    irBuilder.setCurrentBlock(condition_block);
    irBuilder.local_values.clearRetainingCapacity();
    const condition = try walkExpr(test_, irBuilder, alloc);
    try irBuilder.emit(Instruction{
        .branch = .{
            .condition = condition,
            .then_block = body_block,
            .else_block = exit_block,
        },
    });
    try irBuilder.addSuccessor(condition_block, body_block);
    try irBuilder.addSuccessor(condition_block, exit_block);

    // body block
    irBuilder.setCurrentBlock(body_block);
    irBuilder.local_values.clearRetainingCapacity();
    try walkStmtList(body, irBuilder, alloc);
    irBuilder.local_values.clearRetainingCapacity();
    try irBuilder.emit(Instruction{
        .jump = .{ .target = condition_block },
    });
    try irBuilder.addSuccessor(body_block, condition_block);

    // exit block
    irBuilder.setCurrentBlock(exit_block);
    irBuilder.local_values.clearRetainingCapacity();
    try walkStmtList(orelse_, irBuilder, alloc);
    irBuilder.local_values.clearRetainingCapacity();
}

fn getBinOp(expr: *PyObject) !BinOp {
    const op_obj = c.PyObject_GetAttrString(expr, "op");
    std.debug.assert(op_obj != null);
    const name = getPyType(op_obj);

    if (std.mem.eql(u8, name, "Add")) return .add;
    if (std.mem.eql(u8, name, "Sub")) return .sub;
    if (std.mem.eql(u8, name, "Mult")) return .mul;
    if (std.mem.eql(u8, name, "Div")) return .div;

    std.debug.panic("unsupported binop: {s}", .{name});
    return error.NotFound;
}

fn getUnaryOp(expr: *PyObject) !UnaryOp {
    const op_obj = c.PyObject_GetAttrString(expr, "op");
    std.debug.assert(op_obj != null);
    const name = getPyType(op_obj);

    if (std.mem.eql(u8, name, "USub")) return .neg;

    std.debug.panic("unsupported unaryop: {s}", .{name});
    return error.NotFound;
}

fn getCompareOp(expr: *PyObject) !CmpOp {
    const ops = c.PyObject_GetAttrString(expr, "ops");
    std.debug.assert(ops != null);
    const ops_obj = c.PyList_GetItem(ops, 0);
    std.debug.assert(ops_obj != null);

    const name = getPyType(ops_obj);

    if (std.mem.eql(u8, name, "Eq")) return .eq;
    if (std.mem.eql(u8, name, "NotEq")) return .neq;
    if (std.mem.eql(u8, name, "Lt")) return .lt;
    if (std.mem.eql(u8, name, "LtE")) return .lte;
    if (std.mem.eql(u8, name, "Gt")) return .gt;
    if (std.mem.eql(u8, name, "GtE")) return .gte;

    std.debug.panic("unsupported compare op: {s}", .{name});
    return error.NotFound;
}

fn getStmtKind(stmt: *PyObject) StmtKind {
    const name = getPyType(stmt);

    if (std.mem.eql(u8, name, "Assign")) return .Assign;
    if (std.mem.eql(u8, name, "Expr")) return .Expr;
    if (std.mem.eql(u8, name, "If")) return .If;
    if (std.mem.eql(u8, name, "While")) return .While;
    return .Unknown;
}

fn getExprKind(stmt: *PyObject) ExprKind {
    const name = getPyType(stmt);
    if (std.mem.eql(u8, name, "BinOp")) return .BinOp;
    if (std.mem.eql(u8, name, "Compare")) return .Compare;
    if (std.mem.eql(u8, name, "UnaryOp")) return .UnaryOp;
    if (std.mem.eql(u8, name, "Constant")) return .Constant;
    if (std.mem.eql(u8, name, "Name")) return .Name;
    if (std.mem.eql(u8, name, "Call")) return .Call;

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
