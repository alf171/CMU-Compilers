const std = @import("std");
const c = @import("python.zig").c;

const Operand = @import("common").alloc.Operand;
const LocalId = @import("common").ir.LocalId;
const Instruction = @import("common").ir.Instruction;
const BinOp = @import("common").ir.BinOp;
const CmpOp = @import("common").ir.CmpOp;
const Program = @import("common").ir.Program;
const PhiInput = @import("common").ir.PhiInput;
const UnaryOp = @import("common").ir.UnaryOp;

const IrBuilder = @import("builder.zig").IrBuilder;
const LocalValues = @import("builder.zig").LocalValues;

const PyObject = c.PyObject;

const StmtKind = enum { Assign, Expr, If, While, For, Unknown };

const ExprKind = enum { BinOp, UnaryOp, Compare, Constant, Name, Unknown, Call };

pub const LoopCondition = union(enum) {
    expr: *PyObject,
    compare: struct { local: LocalId, cmp: CmpOp, rhs_local: LocalId },
};

pub const ForLoopBody = struct {
    stmt_list: *PyObject,
    condition_var_name: []const u8,
};

pub const LoopBody = union(enum) {
    stmt_list: *PyObject,
    for_loop: ForLoopBody,
};

pub fn walkAst(obj: ?*c.PyObject, alloc: std.mem.Allocator) !Program {
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    errdefer irBuilder.program.deinit(alloc);
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
        .For => try walkFor(raw_stmt, irBuilder, alloc),
        .Unknown => {
            std.debug.print("unsupported statement type: {s}: ", .{getPyType(raw_stmt)});
            printAstDump(raw_stmt);
            return error.UnsupportedStatement;
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
    // get locals orelse use branch value
    irBuilder.local_values.clearRetainingCapacity();
    var all_locals = std.AutoHashMap(LocalId, void).init(alloc);
    defer all_locals.deinit();

    var before_it = before_values.keyIterator();
    while (before_it.next()) |val| {
        try all_locals.put(val.*, {});
    }

    var then_it = then_values.keyIterator();
    while (then_it.next()) |val| {
        try all_locals.put(val.*, {});
    }

    var else_it = else_values.keyIterator();
    while (else_it.next()) |val| {
        try all_locals.put(val.*, {});
    }

    var it = all_locals.keyIterator();
    while (it.next()) |local| {
        const before_value = before_values.get(local.*);
        const then_value = then_values.get(local.*) orelse before_value;
        const else_value = else_values.get(local.*) orelse before_value;

        const has_before = before_value != null;
        const has_then = then_value != null;
        const has_else = else_value != null;
        // variable isn't touch so no need to use a phi
        if (has_then and has_else and then_value.?.equal(else_value.?)) {
            try irBuilder.local_values.put(local.*, before_value.?);
        }
        // emit a phi
        else if (has_then and has_else) {
            const dst = irBuilder.nextTemp();
            const inputs = try alloc.dupe(PhiInput, &.{
                .{ .pred = then_block, .value = then_value.? },
                .{ .pred = else_block, .value = else_value.? },
            });

            try irBuilder.emit(Instruction{
                .phi = .{ .dst = dst, .inputs = inputs, .local = local.* },
            });
            try irBuilder.local_values.put(local.*, dst);
        } else if (!has_before and ((has_then and !has_else) or (!has_then and has_else))) {
            continue;
        } else {
            return error.NotImplemented;
        }
    }
}

//              ------------
//              |          |
//              v          |
// entry -> condition -> body
//              |
//              v
//             exit
// While(test=Compare(...), body=[...], orelse=[...])
pub fn walkWhile(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    const test_ = c.PyObject_GetAttrString(stmt, "test");
    const body = c.PyObject_GetAttrString(stmt, "body");
    const orelse_ = c.PyObject_GetAttrString(stmt, "orelse");
    std.debug.assert(test_ != null);
    std.debug.assert(body != null);
    std.debug.assert(orelse_ != null);

    const Helper = struct {
        fn loopCallback(input_body: LoopBody, irBuilder_: *IrBuilder, alloc_: std.mem.Allocator) anyerror!void {
            const body_ = switch (input_body) {
                .stmt_list => |sl| sl,
                else => return error.BadState,
            };
            try walkStmtList(body_, irBuilder_, alloc_);
        }
    };

    try walkLoop(irBuilder, LoopCondition{ .expr = test_ }, LoopBody{ .stmt_list = body }, Helper.loopCallback, orelse_, alloc);
}

// For(target=Name(id='i', ctx=Store()), iter=Call(func=Name(id='range', ctx=Load()), args=[Constant(value=0), Constant(value=10)]), body=[Expr(value=Call(func=Name(id='print', ctx=Load()), args=[Name(id='i', ctx=Load())]))])
// :skeleton impl:
// for i in range(start, stop):
//     body
// ==>
// i = start
// while i < stop:
//     body
//     i = i + 1
pub fn walkFor(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    const target = c.PyObject_GetAttrString(stmt, "target");
    std.debug.assert(target != null);
    const target_name_obj = c.PyObject_GetAttrString(target, "id");
    std.debug.assert(target_name_obj != null);
    const target_name_raw = c.PyUnicode_AsUTF8(target_name_obj);
    std.debug.assert(target_name_raw != null);
    const target_name = std.mem.span(target_name_raw);

    const iter = c.PyObject_GetAttrString(stmt, "iter");
    std.debug.assert(iter != null);

    const func = c.PyObject_GetAttrString(iter, "func");
    std.debug.assert(func != null);

    const id_obj = c.PyObject_GetAttrString(func, "id");
    std.debug.assert(id_obj != null);

    const name_raw = c.PyUnicode_AsUTF8(id_obj);
    std.debug.assert(name_raw != null);

    const name = std.mem.span(name_raw);
    if (!std.mem.eql(u8, name, "range")) {
        return error.UnsupportedForLoopDef;
    }

    const args = c.PyObject_GetAttrString(iter, "args");
    std.debug.assert(args != null);
    std.debug.assert(c.PyList_Size(args) == 2);

    // use lower bound to initialize condition var
    const local = try irBuilder.getOrCreateLocal(target_name, alloc);
    const lower_bound = c.PyList_GetItem(args, 0);
    const start = try walkExpr(lower_bound, irBuilder, alloc);
    try irBuilder.local_values.put(local, start);
    try irBuilder.emit(Instruction{ .store_local = .{
        .local = local,
        .src = start,
    } });

    const Helper = struct {
        fn loopCallback(input_body_: LoopBody, irBuilder_: *IrBuilder, alloc_: std.mem.Allocator) anyerror!void {
            const body_ = switch (input_body_) {
                .for_loop => |fl| fl,
                else => return error.BadState,
            };

            try walkStmtList(body_.stmt_list, irBuilder_, alloc_);
            // condition_var += 1
            const one = irBuilder_.nextTemp();
            try irBuilder_.emit(Instruction{ .constant = .{
                .dst = one,
                .value = 1,
            } });
            // TODO: could pass localId through instead
            const local_ = try irBuilder_.getOrCreateLocal(body_.condition_var_name, alloc_);

            const temp = irBuilder_.nextTemp();
            try irBuilder_.emit(Instruction{ .binop = .{
                .dst = temp,
                .op = .add,
                .lhs = irBuilder_.local_values.get(local_) orelse return error.NotFound,
                .rhs = one,
            } });
            try irBuilder_.emit(Instruction{ .store_local = .{
                .local = local_,
                .src = temp,
            } });
            try irBuilder_.local_values.put(local_, temp);
        }
    };

    const upper_bound = c.PyList_GetItem(args, 1);
    const stop = try walkExpr(upper_bound, irBuilder, alloc);
    // HACK!
    const stop_local = try irBuilder.getOrCreateLocal("__range_stop", alloc);
    try irBuilder.local_values.put(stop_local, stop);
    try irBuilder.emit(Instruction{ .store_local = .{
        .local = stop_local,
        .src = stop,
    } });
    const body = c.PyObject_GetAttrString(stmt, "body");

    try walkLoop(
        irBuilder,
        LoopCondition{ .compare = .{
            .local = local,
            .cmp = .lt,
            .rhs_local = stop_local,
        } },
        LoopBody{ .for_loop = .{
            .stmt_list = body,
            .condition_var_name = target_name,
        } },
        Helper.loopCallback,
        null,
        alloc,
    );
}

fn walkLoop(
    irBuilder: *IrBuilder,
    condition: LoopCondition,
    body: LoopBody,
    bodyCallback: *const fn (LoopBody, *IrBuilder, std.mem.Allocator) anyerror!void,
    orelse_: ?*PyObject,
    alloc: std.mem.Allocator,
) !void {
    var before_values = try irBuilder.cloneLocalValues(alloc);
    defer before_values.deinit();

    const condition_block = try irBuilder.newBlock(alloc);
    const body_block = try irBuilder.newBlock(alloc);
    const exit_block = try irBuilder.newBlock(alloc);

    const entry_block = irBuilder.current_block;
    try irBuilder.emit(Instruction{ .jump = .{ .target = condition_block } });
    try irBuilder.addSuccessor(entry_block, condition_block);

    irBuilder.setCurrentBlock(condition_block);
    irBuilder.local_values.clearRetainingCapacity();
    var loop_values = LocalValues.init(alloc);
    defer loop_values.deinit();
    var before_it = before_values.iterator();
    while (before_it.next()) |entry| {
        const local = entry.key_ptr.*;
        const before_val = entry.value_ptr.*;

        // loop_values[x] = phi(before_values[x], body_values[x])
        var phi = try alloc.alloc(PhiInput, 2);
        phi[0] = .{ .pred = entry_block, .value = before_val };
        phi[1] = undefined;

        const dst = irBuilder.nextTemp();
        try irBuilder.emit(Instruction{ .phi = .{
            .dst = dst,
            .local = local,
            .inputs = phi,
        } });

        try irBuilder.local_values.put(local, dst);
        try loop_values.put(local, dst);
    }

    const condition_expr = switch (condition) {
        .expr => |cond| try walkExpr(cond, irBuilder, alloc),
        .compare => |comp| blk: {
            const dst = irBuilder.nextTemp();
            const lhs = irBuilder.local_values.get(comp.local) orelse return error.LocalNotFound;
            const rhs = irBuilder.local_values.get(comp.rhs_local) orelse return error.LocalNotFound;
            try irBuilder.emit(Instruction{ .compare = .{
                .dst = dst,
                .lhs = lhs,
                .op = comp.cmp,
                .rhs = rhs,
            } });
            break :blk dst;
        },
    };

    try irBuilder.emit(Instruction{
        .branch = .{
            .condition = condition_expr,
            .then_block = body_block,
            .else_block = exit_block,
        },
    });
    try irBuilder.addSuccessor(condition_block, body_block);
    try irBuilder.addSuccessor(condition_block, exit_block);

    // body block
    irBuilder.setCurrentBlock(body_block);
    // naively restore since we dont support walrus
    try irBuilder.restoreLocalValues(&loop_values);

    // crux
    try bodyCallback(body, irBuilder, alloc);

    var body_values = try irBuilder.cloneLocalValues(alloc);
    defer body_values.deinit();

    for (irBuilder.program.blocks.items[condition_block].instructions.items) |*instruction| {
        switch (instruction.*) {
            .phi => |*p| {
                const value = body_values.get(p.local) orelse p.dst;
                p.inputs[1] = .{
                    .pred = body_block,
                    .value = value,
                };
            },
            else => {},
        }
    }

    try irBuilder.emit(Instruction{
        .jump = .{ .target = condition_block },
    });
    try irBuilder.addSuccessor(body_block, condition_block);

    // exit block
    irBuilder.setCurrentBlock(exit_block);
    // naively restore since we dont support walrus
    try irBuilder.restoreLocalValues(&loop_values);
    if (orelse_) |orelse_val| {
        try walkStmtList(orelse_val, irBuilder, alloc);
    }
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
    if (std.mem.eql(u8, name, "For")) return .For;
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

test "while loop" {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const alloc = std.testing.allocator;
    const code: [*:0]const u8 =
        \\x = 0
        \\while x < 3:
        \\  x = x + 1
        \\  print(x)
        \\print(x)
    ;

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code);
    std.debug.assert(tree != null);

    var program = try walkAst(tree, alloc);
    defer program.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), program.blocks.items.len);

    const entry = program.blocks.items[0].instructions.items;
    const condition = program.blocks.items[1].instructions.items;
    const body = program.blocks.items[2].instructions.items;
    const exit = program.blocks.items[3].instructions.items;

    try std.testing.expectEqualDeep(
        Instruction{ .constant = .{ .dst = .{ .temp = 0 }, .value = 0 } },
        entry[0],
    );
    try std.testing.expectEqualDeep(
        Instruction{ .store_local = .{ .local = 0, .src = .{ .temp = 0 } } },
        entry[1],
    );
    try std.testing.expectEqualDeep(
        Instruction{ .jump = .{ .target = 1 } },
        entry[2],
    );

    switch (condition[0]) {
        .phi => {
            // temp1 = phi(entry: temp0, body: temp4)
        },
        else => return error.ExpectedPhi,
    }

    switch (body[1]) {
        .binop => {},
        else => return error.ExpectedBinOp,
    }

    switch (exit[0]) {
        .print_int => {},
        else => return error.ExpectedPrint,
    }
}
