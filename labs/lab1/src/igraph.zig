// GOAL is to build an interference graph from live_out struct
const std = @import("std");
const parser = @import("parse.zig");

// can consider using parser.Operand.temp instead of i32
const Node = struct {
    neighbors: std.AutoHashMap(parser.Operand, void),

    pub fn init(allocator: std.mem.Allocator) Node {
        return Node{ .neighbors = std.AutoHashMap(parser.Operand, void).init(allocator) };
    }

    pub fn deinit(self: *Node) void {
        self.neighbors.deinit();
    }
};

pub const IGraph = struct {
    nodes: std.AutoHashMap(parser.Operand, Node),

    pub fn init(allocator: std.mem.Allocator) IGraph {
        return IGraph{ .nodes = std.AutoHashMap(parser.Operand, Node).init(allocator) };
    }

    pub fn deinit(self: *IGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            n.deinit();
        }
        self.nodes.deinit();
    }

    pub fn print(self: *IGraph, allocator: std.mem.Allocator) !void {
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

pub fn createIgraph(lines: []parser.Line, allocator: std.mem.Allocator) !IGraph {
    var igraph = IGraph.init(allocator);
    for (lines) |line| {
        try placeNodes(&igraph, line, allocator);
    }
    return igraph;
}

fn placeNodes(igraph: *IGraph, line: parser.Line, allocator: std.mem.Allocator) !void {
    for (line.defines.ops) |define_op| {
        for (line.live_out.ops) |live_out_op| {
            if (!igraph.nodes.contains(define_op)) {
                try igraph.nodes.put(define_op, Node.init(allocator));
            }
            if (!parser.Operand.equal(define_op, live_out_op)) {
                // TODO: could refactor this to add somewhere else
                // add both direction since graph is adirecitonal
                try igraph.nodes.getPtr(define_op).?.neighbors.put(live_out_op, {});
                try igraph.nodes.getPtr(live_out_op).?.neighbors.put(define_op, {});
            }
        }
    }
}
