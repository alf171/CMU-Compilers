// TODO: move some logic from igraph and main into here
const std = @import("std");
const igraph = @import("igraph.zig");
const parser = @import("parse.zig");

const Node = @import("igraph.zig").Node;
const Writer = std.Io.Writer;
const Operand = @import("common").alloc.Operand;

/// merge either src or dest into later if live_out and degree let's us do so
pub fn run(graph: *igraph.IGraph, reg_count: u8, alloc: std.mem.Allocator, stdout: ?*Writer) !void {
    while (try checkForPossibleMerges(graph.*, reg_count, stdout, alloc)) |pair| {
        // try stdout.print("merging {any} and {any}\n", .{ pair.nodeA, pair.nodeB });
        try graph.mergeNodes(pair.nodeA, pair.nodeB);
    }
    // try stdout.flush();
}

fn checkForPossibleMerges(graph: igraph.IGraph, k: u8, _: ?*Writer, alloc: std.mem.Allocator) !?struct { nodeA: Operand, nodeB: Operand } {
    var node_it = graph.nodes.valueIterator();
    while (node_it.next()) |node| {
        var move_it = node.moves.keyIterator();
        while (move_it.next()) |move_id| {
            // try stdout.print("trying coalesce between {any} and {any}\n", .{ node.val, move_id.* });
            const move_node = graph.nodes.get(move_id.*) orelse {
                return error.IllegalGraph;
            };

            // skip coalesces that aren't allowed
            if (node.neighbors.contains(move_id.*)) {
                // try stdout.print("interference failure", .{});
                continue;
            }

            if (try canCoalesce(graph, node.*, move_node, k, alloc)) {
                return .{ .nodeA = node.val, .nodeB = move_id.* };
            } else {
                // try stdout.print("degree failure", .{});
            }
        }
    }
    return null;
}

// https://en.wikipedia.org/wiki/Register_allocation
fn canCoalesce(graph: igraph.IGraph, a: igraph.Node, b: igraph.Node, k: u8, alloc: std.mem.Allocator) !bool {
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
        if (nbor.cur_degree >= k) count += 1;
        try seen.put(nbor_id.*, {});
    }

    var it2 = b.neighbors.keyIterator();
    while (it2.next()) |nbor_id| {
        if (seen.contains(nbor_id.*)) continue;
        const nbor = graph.nodes.get(nbor_id.*) orelse {
            return error.CantFindNode;
        };
        if (nbor.cur_degree >= k) count += 1;
        try seen.put(nbor_id.*, {});
    }

    return count < k;
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

    var a_node = Node.init(a, alloc);
    try a_node.placeNode(p);
    try a_node.placeNode(q);
    var b_node = Node.init(b, alloc);
    try b_node.placeNode(r);
    var p_node = Node.init(p, alloc);
    try p_node.placeNode(a);
    try p_node.placeNode(q);
    try p_node.placeNode(r);
    var q_node = Node.init(q, alloc);
    try q_node.placeNode(p);
    try q_node.placeNode(a);
    try q_node.placeNode(r);
    var r_node = Node.init(r, alloc);
    try r_node.placeNode(b);
    try r_node.placeNode(p);
    try r_node.placeNode(q);

    try graph.nodes.put(a, a_node);
    try graph.nodes.put(b, b_node);
    try graph.nodes.put(p, p_node);
    try graph.nodes.put(q, q_node);
    try graph.nodes.put(r, r_node);

    const can_coalesce = try canCoalesce(graph, a_node, b_node, 3, alloc);
    try std.testing.expect(!can_coalesce);
}
