const std = @import("std");
const ArrayList = std.ArrayList;
const c = @import("python.zig").c;

const Function = @import("common").ir.Function;
const FunctionKind = @import("common").ir.FunctionKind;
const ConstValue = @import("common").ir.ConstValue;
const BasicBlock = @import("common").ir.BasicBlock;
const types = @import("common").types;
const getElementType = @import("common").types.getElementType;
const getElementSize = @import("common").types.getElementSize;
const ownedPointer = @import("common").types.ownedPointer;
const TypeInfo = types.TypeInfo;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const ValueRef = @import("common").ir.ValueRef;
const Param = @import("common").alloc.Param;
const LocalInfo = @import("common").ir.LocalInfo;
const LocalId = @import("common").ir.LocalId;
const Instruction = @import("common").mir.Instruction;
const BinOp = @import("common").ir.BinOp;
const CmpOp = @import("common").ir.CmpOp;
const Program = @import("common").program.Program;
const PhiInput = @import("common").mir.PhiInput;
const UnaryOp = @import("common").ir.UnaryOp;

const IrBuilder = @import("builder.zig").IrBuilder;
const LocalValues = @import("builder.zig").LocalValues;

const LoopBody = @import("loop.zig").LoopBody;
const walkLoop = @import("loop.zig").walkLoop;
const LoopCarry = @import("loop.zig").LoopCarry;
const LoopCondition = @import("loop.zig").LoopCondition;

const PyObject = c.PyObject;

const StmtKind = enum { Assign, AnnotatedAssign, Expr, If, While, For, FuncDef, Return, Pass, ImportFrom, Unknown };

const ExprKind = enum { BinOp, UnaryOp, Compare, Constant, Name, Call, List, Tuple, Subscript, IfExp, Unknown };

const BuiltinCall = enum { Print, Write, Range, Len, Int, Float, GlobalIdx };

const SubscriberTypes = enum { list, tuple, callable };

const RangeBounds = struct {
    start: TypedOperand,
    end: TypedOperand,
};

pub fn walkAstIntoBuilder(obj: ?*c.PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) !void {
    if (obj == null) return;

    const body = c.PyObject_GetAttrString(obj, "body");
    std.debug.assert(body != null);

    try walkStmtList(body, irBuilder, alloc);
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
        .AnnotatedAssign => try walkAnnotatedAssignment(raw_stmt, irBuilder, alloc),
        .Expr => {
            const value = c.PyObject_GetAttrString(raw_stmt, "value");
            _ = try walkExpr(value, irBuilder, null, alloc);
        },
        .If => try walkIf(raw_stmt, irBuilder, alloc),
        .While => try walkWhile(raw_stmt, irBuilder, alloc),
        .For => try walkFor(raw_stmt, irBuilder, alloc),
        .FuncDef => try walkFuncDef(raw_stmt, irBuilder, alloc),
        .Return => try walkReturn(raw_stmt, irBuilder, alloc),
        .Pass => {},
        // ignore bc we are building these concepts into language so importants aren't used
        // currently we do this with Callable -- not requiring an import
        .ImportFrom => {},
        else => {
            std.debug.print("unsupported statement type: {s}: ", .{getPyType(raw_stmt)});
            printAstDump(raw_stmt);
            return error.UnsupportedStatement;
        },
    }
}

fn walkAssignment(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) !void {
    const targets = c.PyObject_GetAttrString(stmt, "targets");
    std.debug.assert(targets != null);

    const lhs = c.PyList_GetItem(targets, 0);
    std.debug.assert(lhs != null);

    const rhs = c.PyObject_GetAttrString(stmt, "value");
    const rhs_value = try walkExpr(rhs, irBuilder, null, alloc);

    const expr = getExprKind(lhs);
    switch (expr) {
        // Assign(targets=[Name(id='x', ctx=Store())], value=Constant(value=3))
        .Name => {
            const id_obj = c.PyObject_GetAttrString(lhs, "id");
            std.debug.assert(id_obj != null);
            const id = c.PyUnicode_AsUTF8(id_obj);

            const local = try irBuilder.getOrCreateLocal(std.mem.span(id), null, alloc);
            try irBuilder.local_values.put(local, rhs_value);
            try irBuilder.emit(Instruction{ .lir = .{ .store_local = .{
                .local = .{
                    .id = local,
                    .name = try alloc.dupe(u8, std.mem.span(id)),
                    .type = rhs_value.type,
                },
                .src = rhs_value,
            } } }, alloc);
        },
        // Assign(targets=[Subscript(value=Name(id='items', ctx=Load()), slice=Constant(value=3), ctx=Store())], value=Constant(value=0))
        .Subscript => {
            const slice_obj = c.PyObject_GetAttrString(lhs, "slice");
            std.debug.assert(slice_obj != null);
            const slice = try walkExpr(slice_obj, irBuilder, null, alloc);
            const value_obj = c.PyObject_GetAttrString(lhs, "value");
            std.debug.assert(value_obj != null);
            const container = try walkExpr(value_obj, irBuilder, null, alloc);

            switch (container.type) {
                .list => {
                    try irBuilder.emit(Instruction{ .list_store = .{
                        .list = container,
                        .index = slice,
                        .src = .{ .top = rhs_value },
                    } }, alloc);
                },
                else => return error.UnexpectedType,
            }
        },
        // Assign(targets=[Tuple(elts=[Name(id='x', ctx=Store()), Name(id='y', ctx=Store())], ctx=Store())], value=Call(func=Name(id='foobar', ctx=Load()), args=[Constant(value=1), Constant(value=2)]))
        .Tuple => {
            const elts = c.PyObject_GetAttrString(lhs, "elts");
            std.debug.assert(elts != null);
            for (0..@intCast(c.PyList_Size(elts))) |i| {
                const elt = c.PyList_GetItem(elts, @intCast(i));
                std.debug.assert(elt != null);
                if (getExprKind(elt) != .Name) return error.UnsupportedTarget;
                const index: TypedOperand = .{
                    .operand = irBuilder.nextTemp(),
                    .type = .i64,
                };
                try irBuilder.emit(.{ .lir = .{ .move = .{
                    .dst = index,
                    .src = .{ .constant = .{ .i64 = @intCast(i) } },
                } } }, alloc);

                const elem_type = switch (rhs_value.type) {
                    .tuple => |tuple| tuple.elements[i],
                    else => return error.ExpectTuple,
                };
                const elem_dst: TypedOperand = .{
                    .operand = irBuilder.nextTemp(),
                    .type = elem_type,
                };

                try irBuilder.emit(.{ .tuple_load = .{
                    .dst = elem_dst,
                    .tuple = rhs_value,
                    .index = index,
                } }, alloc);

                const id_obj = c.PyObject_GetAttrString(elt, "id");
                std.debug.assert(id_obj != null);
                const id = c.PyUnicode_AsUTF8(id_obj);

                const local = try irBuilder.getOrCreateLocal(std.mem.span(id), null, alloc);

                try irBuilder.local_values.put(local, .{
                    .operand = elem_dst.operand,
                    .type = elem_type,
                });
                try irBuilder.emit(.{ .lir = .{ .store_local = .{
                    .local = .{
                        .id = local,
                        .name = try alloc.dupe(u8, std.mem.span(id)),
                        .type = elem_type,
                    },
                    .src = elem_dst,
                } } }, alloc);
            }
        },
        else => {
            printAstDump(stmt);
            return error.NotImpl;
        },
    }
}

// 1. AnnAssign(target=Name(id='a', ctx=Store()), annotation=..., value=Constant(value=5), simple=1)
// 2. AnnAssign(target=Name(id='a', ctx=Store()), annotation=..., value=List(elts=[Constant(value=1), Constant(value=2), Constant(value=3)], ctx=Load()), simple=1)
fn walkAnnotatedAssignment(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) !void {
    const target = c.PyObject_GetAttrString(stmt, "target");
    std.debug.assert(target != null);

    const target_id_obj = c.PyObject_GetAttrString(target, "id");
    const target_id = c.PyUnicode_AsUTF8(target_id_obj);

    const annotation = c.PyObject_GetAttrString(stmt, "annotation");
    const annotation_type = try parseTypeAnnotation(annotation, alloc);
    defer annotation_type.deinit(alloc);
    const rhs = c.PyObject_GetAttrString(stmt, "value");
    const rhs_value = try walkExpr(rhs, irBuilder, annotation_type, alloc);

    const local = try irBuilder.getOrCreateLocal(std.mem.span(target_id), annotation_type, alloc);
    try irBuilder.local_values.put(local, rhs_value);
    try irBuilder.emit(.{ .lir = .{ .store_local = .{
        .local = .{
            .id = local,
            .name = try alloc.dupe(u8, std.mem.span(target_id)),
            .type = annotation_type,
        },
        .src = rhs_value,
    } } }, alloc);
}

pub fn walkExpr(stmt: *PyObject, irBuilder: *IrBuilder, expectedType: ?TypeInfo, alloc: std.mem.Allocator) !TypedOperand {
    switch (getExprKind(stmt)) {
        .BinOp => {
            const left = c.PyObject_GetAttrString(stmt, "left");
            const right = c.PyObject_GetAttrString(stmt, "right");

            const op = try getBinOp(stmt);
            // order here will impact temp numbering
            const lhs = try walkExpr(left, irBuilder, null, alloc);
            const rhs = try walkExpr(right, irBuilder, null, alloc);

            const dst = irBuilder.nextTemp();
            const instruction = Instruction{ .lir = .{ .binop = .{
                .dst = .{ .operand = dst, .type = lhs.type },
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } } };
            try irBuilder.emit(instruction, alloc);
            return TypedOperand{ .operand = dst, .type = lhs.type };
        },
        .UnaryOp => {
            const operand_obj = c.PyObject_GetAttrString(stmt, "operand");
            const src = try walkExpr(operand_obj, irBuilder, null, alloc);
            const dst = irBuilder.nextTemp();
            const op = try getUnaryOp(stmt);
            try irBuilder.emit(Instruction{ .lir = .{ .unaryop = .{
                .dst = .{ .operand = dst, .type = src.type },
                .op = op,
                .src = src,
            } } }, alloc);
            return TypedOperand{ .operand = dst, .type = src.type };
        },
        .Constant => {
            const value_obj = c.PyObject_GetAttrString(stmt, "value");
            std.debug.assert(value_obj != null);
            const value_type = getPyType(value_obj);
            if (std.mem.eql(u8, value_type, "int")) {
                const value = ConstValue{ .i64 = c.PyLong_AsLong(value_obj) };
                const dst = irBuilder.nextTemp();
                try irBuilder.emit(Instruction{ .lir = .{ .move = .{
                    .dst = .{ .operand = dst, .type = .i64 },
                    .src = .{ .constant = value },
                } } }, alloc);
                return TypedOperand{ .operand = dst, .type = .i64 };
            } else if (std.mem.eql(u8, value_type, "float")) {
                const value: ConstValue = .{ .float = c.PyFloat_AsDouble(value_obj) };
                const dst = irBuilder.nextTemp();
                try irBuilder.emit(Instruction{ .lir = .{ .move = .{
                    .dst = .{ .operand = dst, .type = .float },
                    .src = .{ .constant = value },
                } } }, alloc);
                return TypedOperand{ .operand = dst, .type = .float };
            } else if (std.mem.eql(u8, value_type, "bool")) {
                const value: ConstValue = .{ .bool = c.PyObject_IsTrue(value_obj) == 1 };
                const dst = irBuilder.nextTemp();
                try irBuilder.emit(Instruction{ .lir = .{ .move = .{
                    .dst = .{ .operand = dst, .type = .bool },
                    .src = .{ .constant = value },
                } } }, alloc);
                return TypedOperand{ .operand = dst, .type = .bool };
            } else if (std.mem.eql(u8, value_type, "str")) {
                const raw = c.PyUnicode_AsUTF8(value_obj);
                std.debug.assert(raw != null);
                const bytes = std.mem.span(raw);
                const dst = irBuilder.nextTemp();
                var elements: ArrayList(ValueRef) = .empty;
                // var element_types: ArrayList(TypeInfo) = .empty;
                for (bytes) |char| {
                    try elements.append(alloc, .{ .constant = .{
                        .char = char,
                    } });
                    // try element_types.append(alloc, .char);
                }
                // null terminator
                try elements.append(alloc, .{ .constant = .{
                    .char = 0,
                } });
                // try element_types.append(alloc, .char);

                const _type = TypeInfo{
                    .list = .{
                        // .elements = try element_types.toOwnedSlice(alloc),
                        .element = try ownedPointer(.char, alloc),
                        .size = elements.items.len,
                    },
                };

                const typed_dst = TypedOperand{ .operand = dst, .type = _type };
                // TODO: migrate to tuple once tuple[type] is passed through stack more gracefully
                try irBuilder.emit(Instruction{ .list_literal = .{
                    .dst = typed_dst,
                    .elements = try elements.toOwnedSlice(alloc),
                } }, alloc);
                return typed_dst;
            }
            return error.TypeNotImpl;
        },
        // List(elts=[Constant(value=1), Constant(value=2), Constant(value=3)], ctx=Load())
        .List => {
            const elements = c.PyObject_GetAttrString(stmt, "elts");
            std.debug.assert(elements != null);
            const len = c.PyList_Size(elements);
            var result = ArrayList(ValueRef).empty;
            var elem_type: ?TypeInfo = null;
            for (0..@intCast(len)) |i| {
                const elem = c.PyList_GetItem(elements, @as(isize, @intCast(i)));
                std.debug.assert(elem != null);
                const expected_elem_type: ?TypeInfo = if (expectedType) |t| try getElementType(t) else null;
                // [conditional] use constant instead of an operand if we can
                switch (getExprKind(elem)) {
                    .Constant => {
                        const value = c.PyObject_GetAttrString(elem, "value");
                        const value_type = getPyType(value);

                        if (std.mem.eql(u8, value_type, "int")) {
                            const constant_value = ConstValue{ .i64 = c.PyLong_AsLong(value) };
                            try result.append(alloc, .{ .constant = constant_value });
                            if (i == 0) elem_type = expected_elem_type orelse .i64;
                            continue;
                        } else if (std.mem.eql(u8, value_type, "bool")) {
                            const constant_value = ConstValue{ .bool = value == c.Py_True() };
                            try result.append(alloc, .{ .constant = constant_value });
                            if (i == 0) elem_type = .bool;
                            continue;
                        } else {
                            return error.NotImpl;
                        }
                    },
                    else => {
                        const expr = try walkExpr(elem, irBuilder, expected_elem_type, alloc);
                        try result.append(alloc, .{ .top = expr });
                        // HACK: do this elsewhere
                        if (i == 0) elem_type = expr.type;
                    },
                }
            }
            const dst = irBuilder.nextTemp();

            const first_elem_type = elem_type orelse return error.NoTypeFound;
            const type_ = TypeInfo{ .list = .{
                .element = try types.ownedPointer(
                    try first_elem_type.clone(alloc),
                    alloc,
                ),
                .size = @intCast(len),
            } };
            const typed_dst = TypedOperand{ .operand = dst, .type = type_ };
            try irBuilder.emit(Instruction{ .list_literal = .{
                .dst = typed_dst,
                .elements = try result.toOwnedSlice(alloc),
            } }, alloc);
            return typed_dst;
        },
        // Tuple(elts=[Name(id='x', ctx=Load()), Name(id='y', ctx=Load())], ctx=Load())
        .Tuple => {
            const elts_obj = c.PyObject_GetAttrString(stmt, "elts");
            std.debug.assert(elts_obj != null);
            const len: usize = @intCast(c.PyList_Size(elts_obj));
            var elements = try alloc.alloc(ValueRef, len);
            var element_types = try alloc.alloc(TypeInfo, len);
            for (0..len) |i| {
                const elem_obj = c.PyList_GetItem(elts_obj, @intCast(i));
                std.debug.assert(elem_obj != null);
                const elem_op = try walkExpr(elem_obj, irBuilder, null, alloc);
                elements[i] = ValueRef{
                    .top = elem_op,
                };
                element_types[i] = try elem_op.type.clone(alloc);
            }

            const dst = irBuilder.nextTemp();
            const typed_dst = TypedOperand{
                .operand = dst,
                .type = .{ .tuple = .{ .elements = element_types } },
            };
            try irBuilder.emit(.{
                .tuple_literal = .{
                    .dst = typed_dst,
                    .elements = elements,
                },
            }, alloc);
            return typed_dst;
        },
        // Subscript(value=Name(id='items', ctx=Load()), slice=Constant(value=0), ctx=Load())
        .Subscript => {
            const value_obj = c.PyObject_GetAttrString(stmt, "value");
            std.debug.assert(value_obj != null);

            const slice = c.PyObject_GetAttrString(stmt, "slice");
            const index = try walkExpr(slice, irBuilder, null, alloc);

            if (index.type != .i64 and index.type != .i32 and index.type != .any) {
                return error.ArrayIndexMustBeInt;
            }

            const value = try walkExpr(value_obj, irBuilder, null, alloc);
            switch (value.type) {
                .list => |list| {
                    const elem_type = list.element.*;

                    const dst: TypedOperand = .{ .operand = irBuilder.nextTemp(), .type = elem_type };
                    try irBuilder.emit(Instruction{ .list_load = .{
                        .dst = dst,
                        .list = value,
                        .index = index,
                    } }, alloc);
                    return dst;
                },
                .tuple => |tuple| {
                    if (getExprKind(slice) != .Constant) {
                        return error.TupleIndexMustBeConstant;
                    }
                    const index_value_obj = c.PyObject_GetAttrString(slice, "value");
                    std.debug.assert(index_value_obj != null);

                    const raw_index = c.PyLong_AsLong(index_value_obj);
                    const tuple_index: usize = @intCast(raw_index);
                    if (tuple_index < 0) return error.TupleIndexOutOfBounds;
                    if (tuple_index >= tuple.elements.len) return error.TupleIndexOutOfBounds;

                    const dst: TypedOperand = .{
                        .operand = irBuilder.nextTemp(),
                        .type = try tuple.elements[tuple_index].clone(alloc),
                    };
                    try irBuilder.emit(.{ .tuple_load = .{
                        .dst = dst,
                        .tuple = try value.clone(alloc),
                        .index = index,
                    } }, alloc);
                    // any isnt right here but there's some complexity here since at comptime we dont know our type due to the homogenuous types not being ensured
                    return dst;
                },
                else => return error.IndexIntoNonList,
            }
        },
        .Name => {
            const id_obj = c.PyObject_GetAttrString(stmt, "id");
            std.debug.assert(id_obj != null);

            const id = c.PyUnicode_AsUTF8(id_obj);
            std.debug.assert(id != null);

            const name = std.mem.span(id);
            const localId = try irBuilder.getOrCreateLocal(name, null, alloc);

            if (irBuilder.local_values.get(localId)) |value| {
                return value;
            }

            if (irBuilder.findFunction(name)) |function| {
                var params = try alloc.alloc(TypeInfo, function.params.len);
                for (function.params, 0..) |param, i| {
                    params[i] = try param.type.clone(alloc);
                }
                const function_dst: TypedOperand = .{
                    .operand = function.nextTemp(),
                    .type = .{ .callable = .{
                        .params = params,
                        .returns = try ownedPointer(try function.return_type.clone(alloc), alloc),
                    } },
                };
                // declare function we will return
                try irBuilder.emit(.{
                    .function_ref = .{
                        .dst = function_dst,
                        .function_name = try alloc.dupe(u8, function.name),
                    },
                }, alloc);
                return function_dst;
            }
            const local = try irBuilder.locals.items[localId].duplicate(alloc);
            const dst: TypedOperand = .{
                .operand = irBuilder.nextTemp(),
                .type = local.type,
            };
            try irBuilder.emit(.{
                .lir = .{ .load_local = .{ .dst = dst, .local = local } },
            }, alloc);
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

            const lhs = try walkExpr(left_obj, irBuilder, null, alloc);
            const rhs = try walkExpr(right_obj, irBuilder, null, alloc);
            const dst: TypedOperand = .{ .operand = irBuilder.nextTemp(), .type = .bool };
            const op = try getCompareOp(stmt);

            try irBuilder.emit(Instruction{ .lir = .{ .compare = .{
                .dst = dst,
                .lhs = lhs,
                .op = op,
                .rhs = rhs,
            } } }, alloc);

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

            const args = c.PyObject_GetAttrString(stmt, "args");
            std.debug.assert(args != null);

            const builtin = getBuiltinCall(std.mem.span(name));

            if (builtin) |b| {
                switch (b) {
                    .Print => {
                        std.debug.assert(c.PyList_Size(args) == 1);
                        const arg0 = c.PyList_GetItem(args, 0);
                        std.debug.assert(arg0 != null);
                        const src = try walkExpr(arg0, irBuilder, null, alloc);

                        try irBuilder.emit(Instruction{ .print = .{
                            .src = src,
                        } }, alloc);
                        return src;
                    },
                    .Write => {
                        std.debug.assert(c.PyList_Size(args) == 3);
                        const arg0 = c.PyList_GetItem(args, 0);
                        std.debug.assert(arg0 != null);
                        const fd = try walkExpr(arg0, irBuilder, null, alloc);
                        const arg1 = c.PyList_GetItem(args, 1);
                        std.debug.assert(arg1 != null);
                        const buf = try walkExpr(arg1, irBuilder, null, alloc);
                        const arg2 = c.PyList_GetItem(args, 2);
                        std.debug.assert(arg2 != null);
                        const len = try walkExpr(arg2, irBuilder, null, alloc);
                        switch (buf.type) {
                            .list => {
                                // gross but we need to increment past the book keeping size value
                                const eight: TypedOperand = .{ .operand = irBuilder.nextTemp(), .type = .i64 };
                                try irBuilder.emit(.{ .lir = .{ .move = .{
                                    .dst = eight,
                                    .src = .{ .constant = .{ .i64 = 8 } },
                                } } }, alloc);
                                const data = irBuilder.nextTemp();
                                // write returns a pointer
                                try irBuilder.emit(.{ .lir = .{ .binop = .{
                                    .dst = .{ .operand = data, .type = .ptr },
                                    .lhs = buf,
                                    .op = .add,
                                    .rhs = eight,
                                } } }, alloc);
                                const write_args = try alloc.alloc(TypedOperand, 3);
                                write_args[0] = try fd.clone(alloc);
                                write_args[1] = .{ .operand = data, .type = try buf.type.clone(alloc) };
                                write_args[2] = try len.clone(alloc);
                                try irBuilder.emit(.{
                                    .function_call = .{
                                        .dst = null,
                                        .args = write_args,
                                        .callee = .{ .direct = try alloc.dupe(u8, "write") },
                                    },
                                }, alloc);
                            },
                            .tuple => {
                                const write_args = try alloc.alloc(TypedOperand, 3);
                                write_args[0] = try fd.clone(alloc);
                                write_args[1] = try buf.clone(alloc);
                                write_args[2] = try len.clone(alloc);
                                try irBuilder.emit(.{
                                    .function_call = .{
                                        .dst = null,
                                        .args = write_args,
                                        .callee = .{ .direct = try alloc.dupe(u8, "write") },
                                    },
                                }, alloc);
                            },
                            else => |e| {
                                std.debug.print("cant write type {s}\n", .{@tagName(e)});
                                return error.UnsupportedWriteType;
                            },
                        }
                        return .{ .operand = .unknown, .type = .void };
                    },
                    .Len => {
                        std.debug.assert(c.PyList_Size(args) == 1);
                        const arg0 = c.PyList_GetItem(args, 0);
                        std.debug.assert(arg0 != null);
                        const value = try walkExpr(arg0, irBuilder, null, alloc);
                        const dst: TypedOperand = .{ .operand = irBuilder.nextTemp(), .type = .i64 };
                        try irBuilder.emit(.{ .len = .{
                            .dst = dst,
                            .value = value,
                        } }, alloc);
                        return dst;
                    },
                    // Call(func=Name(id='range', ctx=Load()), args=[Constant(value=0), Constant(value=10)])
                    .Range => {
                        const bounds = switch (c.PyList_Size(args)) {
                            1 => blk: {
                                const start = irBuilder.nextTemp();
                                try irBuilder.emit(.{ .lir = .{ .move = .{
                                    .dst = .{ .operand = start, .type = .i64 },
                                    .src = .{ .constant = .{ .i64 = 0 } },
                                } } }, alloc);

                                const endItem = c.PyList_GetItem(args, 0);
                                std.debug.assert(endItem != null);
                                const end = try walkExpr(endItem, irBuilder, null, alloc);

                                break :blk RangeBounds{ .start = TypedOperand{ .type = .i64, .operand = start }, .end = end };
                            },
                            2 => blk: {
                                const startItem = c.PyList_GetItem(args, 0);
                                std.debug.assert(startItem != null);
                                const start = try walkExpr(startItem, irBuilder, null, alloc);
                                const endItem = c.PyList_GetItem(args, 1);
                                std.debug.assert(endItem != null);
                                const end = try walkExpr(endItem, irBuilder, null, alloc);
                                break :blk RangeBounds{ .start = start, .end = end };
                            },
                            else => return error.InvalidBounds,
                        };

                        const dst = irBuilder.nextTemp();

                        const type_ = TypeInfo{
                            .lazy = .{ .value = try ownedPointer(.{ .iterable = .{ .element = try ownedPointer(.i64, alloc) } }, alloc) },
                        };
                        const typed_dst = TypedOperand{ .operand = dst, .type = type_ };
                        try irBuilder.emit(.{ .range = .{
                            .dst = typed_dst,
                            .start = bounds.start,
                            .end = bounds.end,
                        } }, alloc);
                        return typed_dst;
                    },
                    .Int => {
                        std.debug.assert(c.PyList_Size(args) == 1);
                        const arg0 = c.PyList_GetItem(args, 0);
                        std.debug.assert(arg0 != null);
                        const value = try walkExpr(arg0, irBuilder, null, alloc);
                        const dst: TypedOperand = .{
                            .operand = irBuilder.nextTemp(),
                            .type = .i64,
                        };
                        try irBuilder.emit(.{ .lir = .{ .cast = .{
                            .dst = dst,
                            .dst_target_type = .i64,
                            .src = value,
                        } } }, alloc);
                        return dst;
                    },
                    .Float => {
                        std.debug.assert(c.PyList_Size(args) == 1);
                        const arg0 = c.PyList_GetItem(args, 0);
                        std.debug.assert(arg0 != null);
                        const value = try walkExpr(arg0, irBuilder, null, alloc);
                        const dst: TypedOperand = .{
                            .operand = irBuilder.nextTemp(),
                            .type = .float,
                        };
                        try irBuilder.emit(.{ .lir = .{ .cast = .{
                            .dst = dst,
                            .dst_target_type = .float,
                            .src = value,
                        } } }, alloc);
                        return dst;
                    },
                    .GlobalIdx => {
                        const dst: TypedOperand = .{
                            .operand = irBuilder.nextTemp(),
                            .type = .i64,
                        };

                        try irBuilder.emit(.{ .global_idx = .{
                            .dst = dst,
                        } }, alloc);

                        return dst;
                    },
                }
            }

            // arguments are params only declared at call site
            var arguments: ArrayList(TypedOperand) = .empty;
            for (0..@intCast(c.PyList_Size(args))) |i| {
                const arg_obj = c.PyList_GetItem(args, @intCast(i));
                std.debug.assert(arg_obj != null);
                const arg = try walkExpr(arg_obj, irBuilder, null, alloc);
                try arguments.append(alloc, try arg.clone(alloc));
            }
            const name_slice = std.mem.span(name);

            if (irBuilder.getLocal(name_slice) catch null) |local_id| {
                if (irBuilder.local_values.get(local_id)) |callee| {
                    if (callee.type == .callable) {
                        const maybe_dst: ?TypedOperand = if (callee.type.callable.returns.* == .void)
                            null
                        else
                            .{
                                .operand = irBuilder.nextTemp(),
                                .type = callee.type.callable.returns.*,
                            };

                        try irBuilder.emit(.{
                            .function_call = .{
                                .callee = .{ .indirect = try callee.clone(alloc) },
                                .dst = if (maybe_dst) |dst| try dst.clone(alloc) else null,
                                .args = try arguments.toOwnedSlice(alloc),
                            },
                        }, alloc);

                        if (maybe_dst) |dst| return dst;
                        return TypedOperand{ .operand = .unknown, .type = .void };
                    }
                }
            }

            if (irBuilder.findFunction(std.mem.span(name))) |function| {
                const maybe_dst: ?TypedOperand = if (function.return_type == .void)
                    null
                else
                    .{
                        .operand = irBuilder.nextTemp(),
                        .type = function.return_type,
                    };
                try irBuilder.emit(.{
                    .function_call = .{
                        .callee = .{ .direct = try alloc.dupe(u8, name_slice) },
                        .dst = if (maybe_dst) |dst| try dst.clone(alloc) else null,
                        .args = try arguments.toOwnedSlice(alloc),
                    },
                }, alloc);

                if (maybe_dst) |dst| return dst;
                return TypedOperand{ .operand = .unknown, .type = .void };
            }
            std.debug.print("cant find function {s}\n", .{name});
            return error.CantFindFunction;
        },
        // IfExp(test=Name(id='c', ctx=Load()), body=Constant(value='FALSE'), orelse=Constant(value='TRUE'))
        .IfExp => {
            const test_obj = c.PyObject_GetAttrString(stmt, "test");
            const body_obj = c.PyObject_GetAttrString(stmt, "body");
            const orelse_obj = c.PyObject_GetAttrString(stmt, "orelse");
            std.debug.assert(test_obj != null);
            std.debug.assert(body_obj != null);
            std.debug.assert(orelse_obj != null);

            const condition = try walkExpr(test_obj, irBuilder, null, alloc);
            const if_value = try walkExpr(body_obj, irBuilder, null, alloc);
            const else_value = try walkExpr(orelse_obj, irBuilder, null, alloc);

            const dst: TypedOperand = .{
                .operand = irBuilder.nextTemp(),
                .type = if_value.type,
            };
            try irBuilder.emit(.{ .lir = .{ .select = .{
                .dst = dst,
                .condition = condition,
                .if_value = .{ .top = if_value },
                .else_value = .{ .top = else_value },
            } } }, alloc);

            return dst;
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

    const condition = try walkExpr(test_, irBuilder, null, alloc);
    try irBuilder.emit(.{ .lir = .{ .branch = .{
        .condition = condition,
        .then_block = then_block,
        .else_block = else_block,
    } } }, alloc);
    try irBuilder.addSuccessor(irBuilder.current_block, then_block, alloc);
    try irBuilder.addSuccessor(irBuilder.current_block, else_block, alloc);

    // then block
    irBuilder.setCurrentBlock(then_block);
    // restore in case condition set variables
    try irBuilder.restoreLocalValues(&before_values);
    try walkStmtList(body, irBuilder, alloc);
    const then_exit_block = irBuilder.current_block;
    // save then locals
    var then_values = try irBuilder.cloneLocalValues(alloc);
    defer then_values.deinit();
    try irBuilder.emit(.{ .lir = .{
        .jump = .{ .target = merge_block },
    } }, alloc);
    try irBuilder.addSuccessor(then_exit_block, merge_block, alloc);

    // else block
    irBuilder.setCurrentBlock(else_block);
    // restore in case condition set variables
    try irBuilder.restoreLocalValues(&before_values);
    try walkStmtList(orelse_, irBuilder, alloc);
    // save else locals
    const else_exit_block = irBuilder.current_block;
    var else_values = try irBuilder.cloneLocalValues(alloc);
    defer else_values.deinit();
    try irBuilder.emit(.{ .lir = .{
        .jump = .{ .target = merge_block },
    } }, alloc);
    try irBuilder.addSuccessor(else_exit_block, merge_block, alloc);

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
                .{ .pred = then_exit_block, .value = then_value.? },
                .{ .pred = else_exit_block, .value = else_value.? },
            });

            const typed_dst = TypedOperand{ .operand = dst, .type = then_value.?.type };
            try irBuilder.emit(.{
                .phi = .{ .dst = typed_dst, .inputs = inputs },
            }, alloc);
            try irBuilder.local_values.put(local.*, typed_dst);
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

    const callback = struct {
        fn loop(input_body: LoopBody, carries: []LoopCarry, irBuilder_: *IrBuilder, alloc_: std.mem.Allocator) anyerror!void {
            _ = carries;
            const body_ = switch (input_body) {
                .stmt_list => |sl| sl,
                else => return error.BadState,
            };
            try walkStmtList(body_, irBuilder_, alloc_);
        }
    };

    try walkLoop(irBuilder, LoopCondition{ .expr = test_ }, LoopBody{ .stmt_list = body }, &.{}, callback.loop, orelse_, alloc);
}

// arr = [...] # range
// len = len(arr)
// index0 = 0
//
// condition:
//   index = phi(entry: index0, body: index_next)
//   keep_going = (index < len)
//   branch keep_going body exit
//
// body:
//   value = arr[index]
//   body
//   index_next = index + 1
//   jump condition
//
// exit:
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

    const expr = try walkExpr(iter, irBuilder, null, alloc);
    std.debug.assert(expr.type.isIterable());

    const index0 = irBuilder.nextTemp();
    try irBuilder.emit(.{ .lir = .{ .move = .{
        .dst = .{ .operand = index0, .type = .i64 },
        .src = .{ .constant = .{ .i64 = 0 } },
    } } }, alloc);

    const callback = struct {
        fn loop(input_body_: LoopBody, carries: []LoopCarry, irBuilder_: *IrBuilder, alloc_: std.mem.Allocator) anyerror!void {
            const body_ = switch (input_body_) {
                .for_loop => |fl| fl,
                else => return error.BadState,
            };
            // value = arr[index]
            const index = carries[0].current;
            const value = irBuilder_.nextTemp();
            const iterable = if (body_.iterator_local) |local|
                irBuilder_.local_values.get(local) orelse return error.NotFound
            else
                body_.iterator;
            switch (iterable.type) {
                .tuple => {
                    try irBuilder_.emit(.{ .tuple_load = .{
                        .dst = .{ .operand = value, .type = .any },
                        .tuple = iterable,
                        .index = index,
                    } }, alloc_);
                },
                .list => {
                    try irBuilder_.emit(.{ .list_load = .{
                        .dst = .{ .operand = value, .type = .any },
                        .list = iterable,
                        .index = index,
                    } }, alloc_);
                },
                .iterable => {
                    try irBuilder_.emit(.{ .tuple_load = .{
                        .dst = .{ .operand = value, .type = .any },
                        .tuple = iterable,
                        .index = index,
                    } }, alloc_);
                },
                .lazy => {
                    try irBuilder_.emit(.{ .lazy_load = .{
                        .dst = .{ .operand = value, .type = .ptr },
                        .lazy = try iterable.clone(alloc_),
                        .index = index.operand,
                    } }, alloc_);
                },
                else => return error.CantIndexInto,
            }

            const elem_type = try getElementType(iterable.type);
            const local = try irBuilder_.getOrCreateLocal(body_.condition_var_name, elem_type, alloc_);
            const typed_value: TypedOperand = .{
                .operand = value,
                .type = elem_type,
            };
            try irBuilder_.local_values.put(local, typed_value);
            try irBuilder_.emit(.{ .lir = .{ .store_local = .{
                .local = .{
                    .id = local,
                    .name = try alloc_.dupe(u8, body_.condition_var_name),
                    .type = elem_type,
                },
                .src = typed_value,
            } } }, alloc_);

            try walkStmtList(body_.stmt_list, irBuilder_, alloc_);
            // index += 1
            const one = irBuilder_.nextTemp();
            try irBuilder_.emit(.{ .lir = .{ .move = .{
                .dst = .{ .operand = one, .type = .i64 },
                .src = .{ .constant = .{ .i64 = 1 } },
            } } }, alloc_);

            const index_next: TypedOperand = .{ .operand = irBuilder_.nextTemp(), .type = .i64 };
            try irBuilder_.emit(.{ .lir = .{ .binop = .{
                .dst = index_next,
                .lhs = index,
                .op = .add,
                .rhs = .{ .operand = one, .type = .i64 },
            } } }, alloc_);
            carries[0].next = index_next;
        }
    };

    const body = c.PyObject_GetAttrString(stmt, "body");
    var carries = ArrayList(LoopCarry).empty;
    defer carries.deinit(alloc);
    try carries.append(alloc, LoopCarry{ .initial = .{
        .operand = index0,
        .type = .i64,
    }, .current = undefined, .next = null, .inputs = undefined });

    const len_temp: TypedOperand = .{ .operand = irBuilder.nextTemp(), .type = .i64 };

    std.debug.assert(expr.type.isIterable());
    try irBuilder.emit(.{ .len = .{
        .dst = len_temp,
        .value = expr,
    } }, alloc);

    // set for j in jj where type(jj) == array
    const iterator_local: ?LocalId = if (getExprKind(iter) == .Name) blk: {
        const id_obj = c.PyObject_GetAttrString(iter, "id");
        std.debug.assert(id_obj != null);

        const id = c.PyUnicode_AsUTF8(id_obj);
        std.debug.assert(id != null);

        break :blk try irBuilder.getOrCreateLocal(std.mem.span(id), null, alloc);
    } else null;

    try walkLoop(
        irBuilder,
        LoopCondition{ .operand_compare = .{
            .carry_index = 0,
            .cmp = .lt,
            .rhs = len_temp,
        } },
        LoopBody{ .for_loop = .{
            .stmt_list = body,
            .condition_var_name = target_name,
            .iterator = expr,
            .iterator_local = iterator_local,
        } },
        carries.items,
        callback.loop,
        null,
        alloc,
    );
}

// FunctionDef(name='foobar', args=arguments(args=[arg(arg='x'), arg(arg='y')]), body=[Expr(value=Call(func=Name(id='print', ctx=Load()), args=[Name(id='x', ctx=Load())])), Expr(value=Call(func=Name(id='print', ctx=Load()), args=[Name(id='y', ctx=Load())])), Return(value=BinOp(left=Name(id='x', ctx=Load()), op=Add(), right=Name(id='y', ctx=Load())))])
pub fn walkFuncDef(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) anyerror!void {
    const func_name_obj = c.PyObject_GetAttrString(stmt, "name");
    std.debug.assert(func_name_obj != null);
    const func_name = c.PyUnicode_AsUTF8(func_name_obj);
    std.debug.assert(func_name != null);
    const args_obj = c.PyObject_GetAttrString(stmt, "args");
    std.debug.assert(args_obj != null);
    const args_list = c.PyObject_GetAttrString(args_obj, "args");
    std.debug.assert(args_list != null);

    // function params
    var params: ArrayList(Param) = .empty;
    for (0..@intCast(c.PyList_Size(args_list))) |i| {
        const arg_obj = c.PyList_GetItem(args_list, @intCast(i));
        std.debug.assert(arg_obj != null);

        const arg_obj_name = c.PyObject_GetAttrString(arg_obj, "arg");
        std.debug.assert(arg_obj_name != null);
        const annotation = c.PyObject_GetAttrString(arg_obj, "annotation");
        std.debug.assert(annotation != null);
        const arg_type = try parseTypeAnnotation(annotation, alloc);
        const raw_name = c.PyUnicode_AsUTF8(arg_obj_name);
        std.debug.assert(raw_name != null);
        const name = std.mem.span(raw_name);

        try params.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .type = arg_type,
        });
    }
    // default function params
    const default_objs = c.PyObject_GetAttrString(args_obj, "defaults");
    std.debug.assert(default_objs != null);
    const default_len: usize = @intCast(c.PyList_Size(default_objs));
    for (0..default_len) |i| {
        const default_obj = c.PyList_GetItem(default_objs, @intCast(i));
        std.debug.assert(default_obj != null);
        // list aren't consts today...
        if (getExprKind(default_obj) != .Constant)
            return error.InvalidDefault;
        // TODO: share parseConstant with walkExpr
        const value_obj = c.PyObject_GetAttrString(default_obj, "value");
        std.debug.assert(value_obj != null);
        // HACK: assume bool type or fast fail
        if (!std.mem.eql(u8, getPyType(value_obj), "bool")) {
            return error.UnsupportedDefaultType;
        }

        const param_index = params.items.len - default_len + i;
        params.items[param_index].default = .{ .bool = c.PyObject_IsTrue(value_obj) == 1 };
    }

    // return type
    const returns = c.PyObject_GetAttrString(stmt, "returns");
    const return_type = try parseTypeAnnotation(returns, alloc);
    // walk annotation to get function kind
    const kind: FunctionKind = blk: {
        const decorators = c.PyObject_GetAttrString(stmt, "decorator_list");
        std.debug.assert(decorators != null);
        for (0..@intCast(c.PyList_Size(decorators))) |i| {
            // decorator_list=[Name(id='gpu', ctx=Load())]
            const decorator = c.PyList_GetItem(decorators, @intCast(i));
            std.debug.assert(decorator != null);
            if (!std.mem.eql(u8, getPyType(decorator), "Name")) {
                return error.UnsupportedDecorator;
            }
            const id_obj = c.PyObject_GetAttrString(decorator, "id");
            std.debug.assert(id_obj != null);
            const id = c.PyUnicode_AsUTF8(id_obj);
            if (std.mem.eql(u8, std.mem.span(id), "gpu"))
                break :blk .gpu_kernel;
        }
        break :blk .host;
    };

    try irBuilder.program.functions.append(alloc, try Function.init(
        std.mem.span(func_name),
        irBuilder.nextFunctionIdx(),
        try params.toOwnedSlice(alloc),
        return_type,
        irBuilder.function_origin,
        kind,
        alloc,
    ));

    // save function state
    const saved_current_function = irBuilder.current_function;
    const saved_current_block = irBuilder.current_block;
    const saved_next_block = irBuilder.next_block;
    var saved_local_values = try irBuilder.cloneLocalValues(alloc);
    defer saved_local_values.deinit();

    // set function state
    irBuilder.current_function = irBuilder.program.functions.items.len - 1;
    irBuilder.current_block = 0;
    irBuilder.next_block = 1;
    irBuilder.local_values.clearRetainingCapacity();

    // load function params
    const function = try irBuilder.currentFunction();
    for (function.params, 0..) |param, i| {
        const value = TypedOperand{
            .operand = irBuilder.nextTemp(),
            .type = param.type,
        };

        try irBuilder.emit(.{ .function_param = .{
            .dst = try value.clone(alloc),
            .name = try alloc.dupe(u8, param.name),
            .index = i,
        } }, alloc);

        const local = try irBuilder.getOrCreateLocal(param.name, param.type, alloc);
        try irBuilder.local_values.put(local, value);
    }

    const body = c.PyObject_GetAttrString(stmt, "body");
    std.debug.assert(body != null);
    try walkStmtList(body, irBuilder, alloc);
    // restore function state
    irBuilder.current_function = saved_current_function;
    irBuilder.current_block = saved_current_block;
    irBuilder.next_block = saved_next_block;
    try irBuilder.restoreLocalValues(&saved_local_values);
}

// Return(value=BinOp(left=Name(id='x', ctx=Load()), op=Add(), right=Name(id='y', ctx=Load())))
// Return()
fn walkReturn(stmt: *PyObject, irBuilder: *IrBuilder, alloc: std.mem.Allocator) !void {
    const value = c.PyObject_GetAttrString(stmt, "value");
    std.debug.assert(value != null);
    const return_top = if (value == c.Py_None())
        null
    else
        (try walkExpr(value, irBuilder, null, alloc));

    try irBuilder.emit(.{ .function_return = .{
        .value = return_top,
    } }, alloc);
}

fn getBinOp(expr: *PyObject) !BinOp {
    const op_obj = c.PyObject_GetAttrString(expr, "op");
    std.debug.assert(op_obj != null);
    const name = getPyType(op_obj);

    if (std.mem.eql(u8, name, "Add")) return .add;
    if (std.mem.eql(u8, name, "Sub")) return .sub;
    if (std.mem.eql(u8, name, "Mult")) return .mul;
    if (std.mem.eql(u8, name, "Div")) return .div;
    if (std.mem.eql(u8, name, "Mod")) return .mod;
    if (std.mem.eql(u8, name, "LShift")) return .lshift;
    if (std.mem.eql(u8, name, "RShift")) return .rshift;

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
    if (std.mem.eql(u8, name, "AnnAssign")) return .AnnotatedAssign;
    if (std.mem.eql(u8, name, "FunctionDef")) return .FuncDef;
    if (std.mem.eql(u8, name, "Return")) return .Return;
    if (std.mem.eql(u8, name, "Pass")) return .Pass;
    if (std.mem.eql(u8, name, "ImportFrom")) return .ImportFrom;
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
    if (std.mem.eql(u8, name, "List")) return .List;
    if (std.mem.eql(u8, name, "Tuple")) return .Tuple;
    if (std.mem.eql(u8, name, "Subscript")) return .Subscript;
    if (std.mem.eql(u8, name, "IfExp")) return .IfExp;

    return .Unknown;
}

fn getPyType(stmt: *PyObject) []const u8 {
    const _type = c.PyObject_Type(stmt);
    const name_ptr = c.PyObject_GetAttrString(_type, "__name__");
    return std.mem.span(c.PyUnicode_AsUTF8(name_ptr));
}

fn parseTypeAnnotation(annotation: *PyObject, alloc: std.mem.Allocator) !TypeInfo {
    const kind = getPyType(annotation);
    // Name(id='int', ctx=Load())
    if (std.mem.eql(u8, kind, "Name")) {
        const annotation_id_obj = c.PyObject_GetAttrString(annotation, "id");
        std.debug.assert(annotation_id_obj != null);
        const annotation_id = c.PyUnicode_AsUTF8(annotation_id_obj);
        std.debug.assert(annotation_id != null);

        // TODO: use getPyType and enumify it?
        if (std.mem.eql(u8, std.mem.span(annotation_id), "int")) {
            return .i64;
        } else if (std.mem.eql(u8, std.mem.span(annotation_id), "i32")) {
            return .i32;
        } else if (std.mem.eql(u8, std.mem.span(annotation_id), "bool")) {
            return .bool;
        } else if (std.mem.eql(u8, std.mem.span(annotation_id), "float")) {
            return .float;
        } else if (std.mem.eql(u8, std.mem.span(annotation_id), "str")) {
            return .{ .list = .{ .element = try ownedPointer(.char, alloc), .size = null } };
        }
        return error.TypeNotImplemented;
    } else if (std.mem.eql(u8, kind, "Subscript")) {
        const slice_obj = c.PyObject_GetAttrString(annotation, "slice");
        std.debug.assert(slice_obj != null);

        switch (try getSubscriberType(annotation)) {
            // Subscript(value=Name(id='list', ctx=Load()), slice=Name(id='int', ctx=Load()), ctx=Load())
            .list => {
                // recursively get type
                const elem_type = try parseTypeAnnotation(slice_obj, alloc);
                return .{ .list = .{
                    .element = try ownedPointer(elem_type, alloc),
                    .size = null,
                } };
            },
            // Subscript(value=Name(id='tuple', ctx=Load()), slice=Tuple(elts=[Name(id='int', ctx=Load()), Name(id='int', ctx=Load())], ctx=Load()), ctx=Load())
            .tuple => {
                const elts = c.PyObject_GetAttrString(slice_obj, "elts");
                std.debug.assert(elts != null);
                const len: usize = @intCast(c.PyList_Size(elts));
                const elem_types = try alloc.alloc(TypeInfo, len);
                for (0..len) |i| {
                    const elt = c.PyList_GetItem(elts, @intCast(i));
                    std.debug.assert(elt != null);
                    elem_types[i] = try parseTypeAnnotation(elt, alloc);
                }
                return .{ .tuple = .{
                    .elements = elem_types,
                } };
            },
            // Subscript(value=Name(id='Callable', ctx=Load()), slice=Tuple(elts=[List(elts=[Name(id='bool', ctx=Load())], ctx=Load()), Name(id='int', ctx=Load())], ctx=Load()), ctx=Load())
            .callable => {
                const elts = c.PyObject_GetAttrString(slice_obj, "elts");
                std.debug.assert(elts != null);
                const len: usize = @intCast(c.PyList_Size(elts));
                std.debug.assert(len == 2);
                const params_obj = c.PyList_GetItem(elts, 0);
                std.debug.assert(params_obj != null);
                const return_obj = c.PyList_GetItem(elts, 1);
                std.debug.assert(return_obj != null);

                const params_elts = c.PyObject_GetAttrString(params_obj, "elts");
                std.debug.assert(params_elts != null);
                const input_len: usize = @intCast(c.PyList_Size(params_elts));
                const elem_types = try alloc.alloc(TypeInfo, input_len);
                for (0..input_len) |i| {
                    const elt = c.PyList_GetItem(params_elts, @intCast(i));
                    std.debug.assert(elt != null);
                    elem_types[i] = try parseTypeAnnotation(elt, alloc);
                }

                return .{ .callable = .{
                    .params = elem_types,
                    .returns = try ownedPointer(try parseTypeAnnotation(return_obj, alloc), alloc),
                } };
            },
        }
    } else if (std.mem.eql(u8, kind, "Constant")) {
        const value_obj = c.PyObject_GetAttrString(annotation, "value");
        if (value_obj == c.Py_None()) {
            return .void;
        }
    }
    std.debug.print("kind not supported {s}\n", .{kind});
    return error.NotImpl;
}

// TODO: impl
// fn parseConstant(obj: *PyObject) void{}

fn getSubscriberType(annotation: *PyObject) !SubscriberTypes {
    const value_obj = c.PyObject_GetAttrString(annotation, "value");
    std.debug.assert(value_obj != null);
    const id_obj = c.PyObject_GetAttrString(value_obj, "id");
    std.debug.assert(id_obj != null);
    const name = std.mem.span(c.PyUnicode_AsUTF8(id_obj));
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "tuple")) return .tuple;
    if (std.mem.eql(u8, name, "Callable")) return .callable;

    return error.InvalidSubscriber;
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

fn getBuiltinCall(name: []const u8) ?BuiltinCall {
    if (std.mem.eql(u8, name, "range")) {
        return BuiltinCall.Range;
    } else if (std.mem.eql(u8, name, "print")) {
        return BuiltinCall.Print;
    } else if (std.mem.eql(u8, name, "write")) {
        return BuiltinCall.Write;
    } else if (std.mem.eql(u8, name, "len")) {
        return BuiltinCall.Len;
    } else if (std.mem.eql(u8, name, "int")) {
        return BuiltinCall.Int;
    } else if (std.mem.eql(u8, name, "float")) {
        return BuiltinCall.Float;
    } else if (std.mem.eql(u8, name, "global_id")) {
        return BuiltinCall.GlobalIdx;
    }
    return null;
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

    var irBuilder = try IrBuilder.init(.user, alloc);
    defer irBuilder.deinit(alloc);
    errdefer irBuilder.program.deinit(alloc);
    try walkAstIntoBuilder(tree, &irBuilder, alloc);
    var program = irBuilder.program;
    defer program.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), program.main.blocks.items.len);

    const entry = program.main.blocks.items[0].instructions.items;
    const condition = program.main.blocks.items[1].instructions.items;
    const body = program.main.blocks.items[2].instructions.items;
    const exit = program.main.blocks.items[3].instructions.items;

    try std.testing.expectEqualDeep(
        Instruction{ .lir = .{ .move = .{
            .dst = .{ .operand = .{ .temp = .{ .id = 0, .function_id = 0 } }, .type = .i64 },
            .src = .{ .constant = .{ .i64 = 0 } },
        } } },
        entry[0],
    );
    try std.testing.expectEqualDeep(
        Instruction{ .lir = .{ .store_local = .{ .local = LocalInfo{
            .id = 0,
            .name = "x",
            .type = .i64,
        }, .src = .{ .temp = .{ .id = 0, .function_id = 0 } } } } },
        entry[1],
    );
    try std.testing.expectEqualDeep(
        Instruction{ .lir = .{ .jump = .{ .target = 1 } } },
        entry[2],
    );

    switch (condition[0]) {
        .phi => {
            // temp1 = phi(entry: temp0, body: temp4)
        },
        else => return error.ExpectedPhi,
    }

    try std.testing.expectEqual(.lir, std.meta.activeTag(body[1]));
    switch (body[1].lir) {
        .binop => {},
        else => return error.ExpectedBinOp,
    }

    switch (exit[0]) {
        .print => {},
        else => return error.ExpectedPrint,
    }
}
