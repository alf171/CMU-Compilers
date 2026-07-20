// TODO: move some logic from igraph and main into here
const std = @import("std");
const igraph = @import("igraph.zig");
const parser = @import("parse.zig");

const RegisterFile = @import("common").register.RegisterFile;
const Node = @import("igraph.zig").Node;
const Writer = std.Io.Writer;
const Operand = @import("common").alloc.Operand;

/// merge either src or dest into later if live_out and degree let's us do so
pub fn run(graph: *igraph.IGraph, register_file: RegisterFile, alloc: std.mem.Allocator) !void {
    while (try checkForPossibleMerges(graph.*, register_file, alloc)) |pair| {
        try graph.mergeNodes(pair.nodeA, pair.nodeB);
    }
}

fn checkForPossibleMerges(graph: igraph.IGraph, register_file: RegisterFile, alloc: std.mem.Allocator) !?struct { nodeA: Operand, nodeB: Operand } {
    var node_it = graph.nodes.valueIterator();
    while (node_it.next()) |node| {
        var move_it = node.moves.keyIterator();
        while (move_it.next()) |move_id| {
            const move_node = graph.nodes.get(move_id.*) orelse {
                return error.IllegalGraph;
            };

            // skip coalesces that aren't allowed
            if (node.neighbors.contains(move_id.*)) {
                continue;
            }

            if (try canCoalesce(graph, node.*, move_node, register_file, alloc)) {
                return .{ .nodeA = node.val, .nodeB = move_id.* };
            }
        }
    }
    return null;
}

// https://en.wikipedia.org/wiki/Register_allocation
fn canCoalesce(
    graph: igraph.IGraph,
    a: igraph.Node,
    b: igraph.Node,
    register_file: RegisterFile,
    alloc: std.mem.Allocator,
) !bool {
    var seen = std.AutoHashMap(Operand, void).init(alloc);
    defer seen.deinit();
    try seen.put(a.val, {});
    try seen.put(b.val, {});

    var count: usize = 0;
    var it = a.neighbors.keyIterator();
    while (it.next()) |nbor_id| {
        if (seen.contains(nbor_id.*)) continue;
        const nbor = graph.nodes.get(nbor_id.*) orelse {
            return error.CantFindNode;
        };
        if (nbor.cur_degree >= register_file.count) count += 1;
        try seen.put(nbor_id.*, {});
    }

    var it2 = b.neighbors.keyIterator();
    while (it2.next()) |nbor_id| {
        if (seen.contains(nbor_id.*)) continue;
        const nbor = graph.nodes.get(nbor_id.*) orelse {
            return error.CantFindNode;
        };
        if (nbor.cur_degree >= register_file.count) count += 1;
        try seen.put(nbor_id.*, {});
    }

    return count < register_file.count;
}

//  (a+b)
//  / | \
// p--q--r
test "reject coalesce" {
    const alloc = std.testing.allocator;
    var graph = igraph.IGraph.init(alloc);
    defer graph.deinit();
    const a = Operand{ .temp = .{ .id = 0, .function_id = 0 } };
    const b = Operand{ .temp = .{ .id = 1, .function_id = 0 } };
    const p = Operand{ .temp = .{ .id = 2, .function_id = 0 } };
    const q = Operand{ .temp = .{ .id = 3, .function_id = 0 } };
    const r = Operand{ .temp = .{ .id = 4, .function_id = 0 } };

    var a_node = Node.init(a, .gp, alloc);
    try a_node.placeNode(p);
    try a_node.placeNode(q);
    var b_node = Node.init(b, .gp, alloc);
    try b_node.placeNode(r);
    var p_node = Node.init(p, .gp, alloc);
    try p_node.placeNode(a);
    try p_node.placeNode(q);
    try p_node.placeNode(r);
    var q_node = Node.init(q, .gp, alloc);
    try q_node.placeNode(p);
    try q_node.placeNode(a);
    try q_node.placeNode(r);
    var r_node = Node.init(r, .gp, alloc);
    try r_node.placeNode(b);
    try r_node.placeNode(p);
    try r_node.placeNode(q);

    try graph.nodes.put(a, a_node);
    try graph.nodes.put(b, b_node);
    try graph.nodes.put(p, p_node);
    try graph.nodes.put(q, q_node);
    try graph.nodes.put(r, r_node);

    const can_coalesce = try canCoalesce(
        graph,
        a_node,
        b_node,
        .{
            .count = 3,
            .type = .gp,
            .forbidden_mask = 0,
        },
        alloc,
    );
    try std.testing.expect(!can_coalesce);
}
