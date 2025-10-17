const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");
const spill = @import("spill.zig");
const live = @import("live.zig");

/// feedback loop of program (lines of IR) -> inteference graph -> colored graph
/// if we spill, create a new IR lines and repeat
fn loop(init_program: *parser.Program, allocator: std.mem.Allocator, _: *std.io.Writer) !color.ColoredGraph {
    var graph = try igraph.createIgraph(init_program.lines, allocator);
    if (try igraph.checkForPossibleMerges(graph, init_program.register_count)) |pair| {
        // TODO: find out who is source and who is dest
        try graph.mergeNodes(pair.nodeA, pair.nodeB);
    }
    var graph_attempt = try color.colorGraph(&graph, init_program.register_count, allocator);

    var program = init_program;
    defer graph.deinit();

    while (graph_attempt == .spill_register) {
        // free previous graph
        graph.deinit();
        const new_program = try spill.spillReg(program, graph_attempt.spill_register, allocator);
        try live.calculateLiveOut(new_program.lines);
        program.deinit();
        program.* = new_program;
        // try program.print(writer);
        graph = try igraph.createIgraph(program.lines, allocator);
        // TODO: this should actually be a loop and we keep trying to merge until we cant anymore
        if (try igraph.checkForPossibleMerges(graph, program.register_count)) |pair| {
            std.log.debug("merging {any} and {any}", .{ pair.nodeA, pair.nodeB });
            // TODO: find out who is source and who is dest
            try graph.mergeNodes(pair.nodeA, pair.nodeB);
            try igraph.swapNode(graph, pair.nodeA, pair.nodeB);
        }
        graph_attempt = try color.colorGraph(&graph, program.register_count, allocator);
        std.debug.print("tag = {s}\n", .{@tagName(graph_attempt)});
    }

    // graph.deinit();
    return graph_attempt.graph;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloctar = gpa.allocator();
    // Grab command-line arguments
    const args = try std.process.argsAlloc(alloctar);
    defer std.process.argsFree(alloctar, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} <filename>\n", .{args[0]});
        return;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const filename = args[1];
    var program: parser.Program = try parser.parse(filename, alloctar);
    defer program.deinit();

    // try program.print(stdout);

    var colored_graph = try loop(&program, alloctar, stdout);
    defer colored_graph.deinit();

    try colored_graph.print(alloctar, stdout);
}

test "run all tests in this project" {
    std.testing.refAllDecls(@This());
}
