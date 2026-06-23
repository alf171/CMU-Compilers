const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");
const spill = @import("spill.zig");
const live = @import("live.zig");
const coalesce = @import("coalesce.zig");

const Allocator = std.mem.Allocator;
const AllocProgram = @import("common").alloc.AllocProgram;
const IrProgram = @import("common").program.Program;
const Writer = std.Io.Writer;

pub const RunResult = struct {
    spill_rounds: usize,
    graph: color.ColoredGraph,
};

/// feedback loop of program (lines of IR) -> inteference graph -> colored graph
/// if we spill, create a new IR lines and repeat
pub fn run(ir_program: *IrProgram, init_program: *AllocProgram, should_coalesce: bool, alloc: Allocator, stdout: ?*Writer) !RunResult {
    var graph = try igraph.createIgraph(init_program.lines, alloc);
    if (should_coalesce) {
        try coalesce.run(&graph, init_program.register_count, alloc, stdout);
    }
    var graph_attempt = try color.colorGraph(&graph, init_program.register_count, alloc);
    var color_attemps: usize = 0;

    var program = init_program;
    defer graph.deinit();

    while (graph_attempt == .spill_register) {
        // free previous graph
        graph.deinit();
        // spill alloc
        var new_program = try spill.spillReg(program, graph_attempt.spill_register, alloc);
        color_attemps += 1;
        // split in ir
        try spill.spillRegInIr(ir_program, program, graph_attempt.spill_register, alloc);
        try live.calculateLiveOut(&new_program, alloc);
        program.deinit(alloc);
        program.* = new_program;
        // try program.print(stdout);
        graph = try igraph.createIgraph(program.lines, alloc);
        if (should_coalesce) {
            try coalesce.run(&graph, program.register_count, alloc, stdout);
        }
        graph_attempt = try color.colorGraph(&graph, program.register_count, alloc);
    }

    // return graph_attempt.graph;
    return .{
        .graph = graph_attempt.graph,
        .spill_rounds = color_attemps,
    };
}

test "test" {
    std.testing.refAllDecls(@This());
}
