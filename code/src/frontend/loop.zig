const std = @import("std");
const ArrayList = std.array_list.Managed;
const c = @import("python.zig").c;
const PyObject = c.PyObject;

const IrBuilder = @import("builder.zig").IrBuilder;
const LocalId = @import("common").ir.LocalId;
const CmpOp = @import("common").ir.CmpOp;
const TypedOperand = @import("common").alloc.TypedOperand;
const PhiInput = @import("common").ir.PhiInput;
const Instruction = @import("common").ir.Instruction;
const LocalValues = @import("builder.zig").LocalValues;
const LoopPhi = @import("common").ir.LoopPhi;
const walkExpr = @import("walk.zig").walkExpr;
const walkStmtList = @import("walk.zig").walkStmtList;

pub const LoopCondition = union(enum) { expr: *PyObject, compare: struct { local: LocalId, cmp: CmpOp, rhs_local: LocalId }, operand_compare: struct {
    carry_index: usize,
    cmp: CmpOp,
    rhs: TypedOperand,
} };

pub const LoopBody = union(enum) {
    stmt_list: *PyObject,
    for_loop: ForLoopBody,
};

pub const ForLoopBody = struct {
    stmt_list: *PyObject,
    condition_var_name: []const u8,
    iterator: TypedOperand,
    iterator_local: ?LocalId,
};

// used for phi book keeping within our callback
pub const LoopCarry = struct {
    initial: TypedOperand,
    current: TypedOperand,
    next: ?TypedOperand,
    inputs: []PhiInput,
};

pub fn walkLoop(
    irBuilder: *IrBuilder,
    condition: LoopCondition,
    body: LoopBody,
    carries: []LoopCarry,
    bodyCallback: *const fn (LoopBody, []LoopCarry, *IrBuilder, std.mem.Allocator) anyerror!void,
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
    var loop_phis = ArrayList(LoopPhi).init(alloc);
    defer loop_phis.deinit();

    var before_it = before_values.iterator();
    // shadowed values causing phis
    while (before_it.next()) |entry| {
        const local = entry.key_ptr.*;
        const before_val = entry.value_ptr.*;

        var inputs = try alloc.alloc(PhiInput, 2);
        inputs[0] = .{ .pred = entry_block, .value = before_val.operand };
        inputs[1] = undefined;

        const dst = TypedOperand{
            .operand = irBuilder.nextTemp(),
            .type = before_val.type,
        };
        try irBuilder.emit(Instruction{ .phi = .{
            .dst = dst,
            .inputs = inputs,
        } });
        try irBuilder.local_values.put(local, dst);
        try loop_values.put(local, dst);
        try loop_phis.append(LoopPhi{
            .local = local,
            .phi_inputs = inputs,
            .dst = dst,
        });
    }

    // callee defined phis
    for (carries) |*carry| {
        var inputs = try alloc.alloc(PhiInput, 2);
        inputs[0] = .{ .pred = entry_block, .value = carry.initial.operand };
        inputs[1] = undefined;
        const dst = TypedOperand{
            .operand = irBuilder.nextTemp(),
            .type = carry.initial.type,
        };
        try irBuilder.emit(Instruction{ .phi = .{
            .dst = dst,
            .inputs = inputs,
        } });

        carry.current = dst;
        carry.inputs = inputs;
    }

    const condition_expr = switch (condition) {
        .expr => |cond| (try walkExpr(cond, irBuilder, alloc)).operand,
        .compare => |comp| blk: {
            const dst = irBuilder.nextTemp();
            const lhs = irBuilder.local_values.get(comp.local) orelse return error.LocalNotFound;
            const rhs = irBuilder.local_values.get(comp.rhs_local) orelse return error.LocalNotFound;
            try irBuilder.emit(Instruction{ .compare = .{
                .dst = dst,
                .lhs = lhs.operand,
                .op = comp.cmp,
                .rhs = rhs.operand,
            } });
            break :blk dst;
        },
        .operand_compare => |comp| blk: {
            const dst = irBuilder.nextTemp();
            const lhs = carries[comp.carry_index].current;
            try irBuilder.emit(Instruction{ .compare = .{
                .dst = dst,
                .lhs = lhs.operand,
                .op = comp.cmp,
                .rhs = comp.rhs.operand,
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
    try bodyCallback(body, carries, irBuilder, alloc);

    var body_values = try irBuilder.cloneLocalValues(alloc);
    defer body_values.deinit();
    for (loop_phis.items) |loop_phi| {
        const value = body_values.get(loop_phi.local) orelse loop_phi.dst;
        loop_phi.phi_inputs[1] = .{
            .pred = body_block,
            .value = value.operand,
        };
    }

    for (carries) |carry| {
        const value = carry.next orelse return error.CarryNotSet;
        carry.inputs[1] = .{
            .pred = body_block,
            .value = value.operand,
        };
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
