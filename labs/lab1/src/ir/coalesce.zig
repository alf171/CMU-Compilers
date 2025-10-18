// TODO: move some logic from igraph and main into here
const std = @import("std");
const igraph = @import("igraph.zig");
const parser = @import("parse.zig");

const Operand = parser.Operand;

/// merge either src or dest into later if live_out and degree let's us do so
pub fn run(graph: *igraph.IGraph, reg_count: u8, stdout: *std.io.Writer) !void {
    while (try checkForPossibleMerges(graph.*, reg_count, stdout)) |pair| {
        try stdout.print("merging {any} and {any}\n", .{ pair.nodeA, pair.nodeB });
        try graph.mergeNodes(pair.nodeA, pair.nodeB);
        try swapNode(graph.*, pair.nodeA, pair.nodeB);
    }
    try stdout.flush();
}

fn checkForPossibleMerges(graph: igraph.IGraph, k: u8, _: *std.io.Writer) !?struct { nodeA: Operand, nodeB: Operand } {
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

            if (try canCoalesce(graph, node.*, move_node, k)) {
                return .{ .nodeA = node.val, .nodeB = move_id.* };
            } else {
                // try stdout.print("degree failure", .{});
            }
        }
    }
    return null;
}

fn canCoalesce(graph: igraph.IGraph, a: igraph.Node, b: igraph.Node, k: u8) !bool {
    var count: usize = 0;
    var it = a.neighbors.keyIterator();
    while (it.next()) |nbor_id| {
        if (b.neighbors.contains(nbor_id.*)) {
            const nbor = graph.nodes.get(nbor_id.*) orelse {
                return error.CantFindNode;
            };
            if (nbor.cur_degree >= k) count += 1;
        }
    }

    var it2 = b.neighbors.keyIterator();
    while (it2.next()) |nbor_id| {
        if (a.neighbors.contains(nbor_id.*)) {
            const nbor = graph.nodes.get(nbor_id.*) orelse {
                return error.CantFindNode;
            };
            if (nbor.cur_degree >= k) count += 1;
        }
    }

    return count < k;
}

fn swapNode(graph: igraph.IGraph, new: Operand, remove: Operand) !void {
    var node_it = graph.nodes.valueIterator();
    while (node_it.next()) |node| {
        var nbor_it = node.neighbors.keyIterator();
        while (nbor_it.next()) |nbor_id| {
            if (nbor_id.equal(remove)) {
                _ = node.neighbors.remove(nbor_id.*);
                try node.neighbors.put(new, {});
            }
        }
    }
}
