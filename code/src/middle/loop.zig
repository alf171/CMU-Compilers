const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");
const spill = @import("spill.zig");
const live = @import("live.zig");
const coalesce = @import("coalesce.zig");
const reg_alloc = @import("reg_alloc.zig");
const reg_class = @import("reg_class.zig");

const Allocator = std.mem.Allocator;
const AllocProgram = @import("common").alloc.AllocProgram;
const IrProgram = @import("common").program.Program;
const Function = @import("common").ir.Function;
const FunctionType = @import("common").ir.FunctionType;
const RegisterFile = @import("common").register.RegisterFile;
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
    register_file: RegisterFile,
    should_coalesce: bool,
    alloc: Allocator,
) !RunResult {
    if (should_coalesce) {
        try coalesce.run(graph, register_file, alloc);
    }
    var graph_attempt = try color.colorGraph(graph, register_file, alloc);
    var color_attemps = std.EnumArray(FunctionType, usize).initFill(0);

    var program = init_program;

    while (graph_attempt == .spill_register) {
        const spilled = graph_attempt.spill_register;
        const function = switch (spilled) {
            .temp => |t| try getFunctionFromIdx(ir_program, t.function_id),
            else => return error.BadSpill,
        };
        // std.debug.print("spilling {s} register in function {s}\n", .{
        //     @tagName(register_file.type),
        //     function.name,
        // });
        color_attemps.getPtr(function.origin).* += 1;

        // spill in ir
        try spill.spillRegInIr(ir_program, graph_attempt.spill_register, alloc);
        // select register types
        var reg_classes = try reg_class.classify(ir_program.*, alloc);
        defer reg_classes.deinit();
        // rebuild alloc according to our spill
        var new_program = try reg_alloc.build(ir_program.*, &reg_classes, alloc);
        errdefer new_program.deinit(alloc);

        try live.calculateLiveOut(&new_program, alloc);
        var new_graph = try igraph.createIgraph(
            new_program.lines,
            register_file,
            alloc,
        );
        errdefer new_graph.deinit();
        if (should_coalesce) {
            try coalesce.run(&new_graph, register_file, alloc);
        }
        const new_graph_attempt = try color.colorGraph(&new_graph, register_file, alloc);
        // commit replacements
        program.deinit(alloc);
        program.* = new_program;
        graph.deinit();
        graph.* = new_graph;
        graph_attempt = new_graph_attempt;
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
