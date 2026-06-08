const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");
const spill = @import("spill.zig");
const live = @import("live.zig");
const coalesce = @import("coalesce.zig");
const lower = @import("lower.zig");

const Allocator = std.mem.Allocator;
const AllocProgram = @import("common").alloc.AllocProgram;
const IrProgram = @import("common").ir.Program;
const Writer = std.Io.Writer;

/// feedback loop of program (lines of IR) -> inteference graph -> colored graph
/// if we spill, create a new IR lines and repeat
pub fn run(ir_program: *IrProgram, init_program: *AllocProgram, should_coalesce: bool, alloc: Allocator, stdout: ?*Writer) !color.ColoredGraph {
    var graph = try igraph.createIgraph(init_program.lines, alloc);
    if (should_coalesce) {
        try coalesce.run(&graph, init_program.register_count, alloc, stdout);
    }
    var graph_attempt = try color.colorGraph(&graph, init_program.register_count, alloc);

    var program = init_program;
    defer graph.deinit();

    while (graph_attempt == .spill_register) {
        // free previous graph
        graph.deinit();
        // spill alloc
        var new_program = try spill.spillReg(program, graph_attempt.spill_register, alloc);
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
        std.debug.print("tag = {s}\n", .{@tagName(graph_attempt)});
    }

    // graph.deinit();
    return graph_attempt.graph;
}

test "run all tests in this project" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(lower);
}
