const std = @import("std");
const parser = @import("parse.zig");
const igraph = @import("igraph.zig");
const color = @import("color.zig");

fn print_program(program: parser.Program, A: std.mem.Allocator) !void {
    // TODO: move into parser
    // call each print method uniquely
    // then pass writter (std.io.getStdOut().writer())
    // this allows less individual heap allocs of strings
    std.debug.print("register count: {d}\n", .{program.register_count});
    for (program.lines, 0..) |line, i| {
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
    defer {
        for (program.lines) |*l| {
            l.deinit();
        }
        A.free(program.lines);
    }

    // try print_program(program, A);

    var graph = try igraph.createIgraph(program.lines, A);
    defer graph.deinit();

    std.log.debug("interference graph below", .{});
    try graph.print(A);

    var colored_graph = try color.colorGraph(&graph, program.register_count, A);
    defer colored_graph.deinit();

    std.log.debug("colored graph below", .{});
    try colored_graph.print(A);
}

test "run all tests in this project" {
    std.testing.refAllDecls(@This());
}
