// goal of this file is to go from interference graph to a colored inteference graph
const std = @import("std");
const parser = @import("parse.zig");
const graph = @import("igraph.zig");

pub const ColoredNode = struct {
    node: graph.Node,
    register: i32,
};

pub const ColoredGraph = struct {
    nodes: std.AutoHashMap(parser.Operand, ColoredNode),

    // compose a node with a register since we need it for coloring
    pub fn init(input: *graph.IGraph, allocator: std.mem.Allocator) ColoredGraph {
        var cg = ColoredGraph{
            .nodes = std.AutoHashMap(parser.Operand, ColoredNode).init(allocator),
        };
        const it = input.nodes.iterator();
        while (it.next()) |v| {
            const key = v.key_ptr;
            const val = ColoredNode{ .node = &v.value_ptr, .register = null };
            cg.nodes.put(key, val);
        }
        return cg;
    }

    pub fn deinit(self: *ColoredGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            n.node.deinit();
        }
        self.nodes.deinit();
    }

    // TODO: this print is copy pasta and does handle different semantics of IGraph vs ColoredGraph
    pub fn print(self: *ColoredGraph, allocator: std.mem.Allocator) !void {
        var it = self.nodes.iterator();
        while (it.next()) |node_ptr| {
            const key_str = try node_ptr.key_ptr.*.toString(allocator);
            defer allocator.free(key_str);
            const value = node_ptr.value_ptr.*;

            var buf = std.array_list.Managed(u8).init(allocator);
            var inner_it = value.neighbors.iterator();
            while (inner_it.next()) |value_ptr| {
                const str = try value_ptr.key_ptr.toString(allocator);
                defer allocator.free(str);
                try buf.appendSlice(str);
                try buf.appendSlice(", ");
            }

            std.debug.print("{s} -> {s}\n", .{ key_str, buf.items });
            defer buf.deinit();
        }
    }
};

pub fn colorGraph(input: graph.IGraph, allocator: std.mem.Allocator) ColoredGraph {
    return ColoredGraph.init(input, allocator);
}
