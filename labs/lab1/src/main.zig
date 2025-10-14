const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");
const spill = @import("spill.zig");

fn print_program(program: parser.Program, A: std.mem.Allocator) !void {
    // TODO: move into parser
    // call each print method uniquely
    // then pass writter (std.io.getStdOut().writer())
    // this allows less individual heap allocs of strings
    std.debug.print("register count: {d}\n", .{program.register_count});
    for (program.lines.items, 0..) |line, i| {
        const uses = try line.uses.toJoinedString(A);
        defer A.free(uses);

        const defs = try line.defines.toJoinedString(A);
        defer A.free(defs);

        const live = try line.live_out.toJoinedString(A);
        defer A.free(live);

        std.debug.print(
            "line[{d}] = (uses: {s}, defines: {s}, live_out: {s}, move: {}, line num: {d})\n",
            .{ i, uses, defs, live, line.move, line.line_number },
        );
    }
}

/// feedback loop of program (lines of IR) -> inteference graph -> colored graph
/// if we spill, create a new IR lines and repeat
fn loop(init_program: parser.Program, allocator: std.mem.Allocator) !color.ColoredGraph {
    var graph = try igraph.createIgraph(init_program.lines, allocator);
    var graph_attempt = try color.colorGraph(&graph, init_program.register_count, allocator);

    var program = init_program;
    while (graph_attempt == .spill_register) {
        // free previous graph
        graph.deinit();
        program = try spill.spillReg(program, graph_attempt.spill_register, allocator);
        std.log.debug("program after spill", .{});
        try print_program(program, allocator);
        graph = try igraph.createIgraph(program.lines, allocator);
        graph_attempt = try color.colorGraph(&graph, program.register_count, allocator);
    }

    graph.deinit();
    return graph_attempt.graph;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    // Grab command-line arguments
    const args = try std.process.argsAlloc(A);
    defer std.process.argsFree(A, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} <filename>\n", .{args[0]});
        return;
    }

    const filename = args[1];
    const program: parser.Program = try parser.parse(filename, A);
    defer program.deinit();

    std.log.debug("init program<>", .{});
    try print_program(program, A);

    var colored_graph = try loop(program, A);
    defer colored_graph.deinit();

    // std.log.debug("colored graph below", .{});
    try colored_graph.print(A);
}

test "run all tests in this project" {
    std.testing.refAllDecls(@This());
}
