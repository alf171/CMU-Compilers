const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");
const spill = @import("spill.zig");
const live = @import("live.zig");
const coalesce = @import("coalesce.zig");
const reg_alloc = @import("reg_alloc.zig");

const Allocator = std.mem.Allocator;
const AllocProgram = @import("common").alloc.AllocProgram;
const IrProgram = @import("common").program.Program;
const Function = @import("common").ir.Function;
const FunctionType = @import("common").ir.FunctionType;
const Writer = std.Io.Writer;

pub const RunResult = struct {
    spill_rounds: std.EnumArray(FunctionType, usize),
    graph: color.ColoredGraph,
};

/// feedback loop of program (lines of IR) -> inteference graph -> colored graph
/// if we spill, create a new IR lines and repeat
pub fn run(
    ir_program: *IrProgram,
    graph: *igraph.IGraph,
    init_program: *AllocProgram,
    should_coalesce: bool,
    register_mask: u32,
    alloc: Allocator,
    stdout: ?*Writer,
) !RunResult {
    if (should_coalesce) {
        try coalesce.run(graph, init_program.register_count, alloc, stdout);
    }
    var graph_attempt = try color.colorGraph(graph, init_program.register_count, alloc);
    var color_attemps = std.EnumArray(FunctionType, usize).initFill(0);

    var program = init_program;

    while (graph_attempt == .spill_register) {
        const spilled = graph_attempt.spill_register;
        const function = switch (spilled) {
            .temp => |t| try getFunctionFromIdx(ir_program, t.function_id),
            else => return error.BadSpill,
        };
        color_attemps.getPtr(function.origin).* += 1;

        // free previous graph
        graph.deinit();
        // spill in ir
        try spill.spillRegInIr(ir_program, graph_attempt.spill_register, alloc);
        // rebuild alloc according to our spill
        var new_program = try reg_alloc.build(ir_program.*, program.register_count, alloc);
        try live.calculateLiveOut(&new_program, alloc);
        program.deinit(alloc);
        program.* = new_program;
        // try program.print(stdout);
        graph.* = try igraph.createIgraph(program.lines, register_mask, alloc);
        if (should_coalesce) {
            try coalesce.run(graph, program.register_count, alloc, stdout);
        }
        graph_attempt = try color.colorGraph(graph, program.register_count, alloc);
    }

    // return graph_attempt.graph;
    return .{
        .graph = graph_attempt.graph,
        .spill_rounds = color_attemps,
    };
}

fn getFunctionFromIdx(program: *const IrProgram, function_idx: usize) !*const Function {
    if (program.main.id == function_idx) return &program.main;
    for (program.functions.items) |*function| {
        if (function.id == function_idx) {
            return function;
        }
    }
    return error.CantFindFunction;
}

test "test" {
    std.testing.refAllDecls(@This());
}
