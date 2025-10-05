// GOAL is to build an interference graph from live_out struct
const std = @import("std");
const parser = @import("parse.zig");

pub const Node = struct {
    // TODO: consider value of duplicate term
    val: parser.Operand,
    neighbors: std.AutoHashMap(parser.Operand, void),
    moves: std.AutoHashMap(parser.Operand, void),
    // only field which is different from color.Node
    // TODO: consider using composition / inheritence to fix this
    selected: bool = false,
    spill: bool = false,
    static_degree: u8 = 0,
    cur_degree: u8 = 0,

    pub fn init(val: parser.Operand, allocator: std.mem.Allocator) Node {
        return Node{ .val = val, .neighbors = std.AutoHashMap(parser.Operand, void).init(allocator), .moves = std.AutoHashMap(parser.Operand, void).init(allocator) };
    }

    pub fn deinit(self: *Node) void {
        self.neighbors.deinit();
        self.moves.deinit();
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
            // we store val on node itself too now
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
            try defineNodeIfDoesntExist(igraph, define_op, allocator);
            // build graph
            if (!parser.Operand.equal(define_op, live_out_op)) {
                std.debug.assert(igraph.nodes.contains(live_out_op));
                std.debug.assert(igraph.nodes.contains(define_op));
                try igraph.nodes.getPtr(define_op).?.neighbors.put(live_out_op, {});
                igraph.nodes.getPtr(define_op).?.static_degree += 1;
                igraph.nodes.getPtr(define_op).?.cur_degree += 1;
                try igraph.nodes.getPtr(live_out_op).?.neighbors.put(define_op, {});
                igraph.nodes.getPtr(live_out_op).?.static_degree += 1;
                igraph.nodes.getPtr(live_out_op).?.cur_degree += 1;
            }
        }
    }
    // keep track of moves
    if (line.move) {
        std.debug.assert(line.defines.ops.len == 1);
        std.debug.assert(line.uses.ops.len == 1);
        const define = line.defines.ops[0];
        const uses = line.uses.ops[0];
        std.debug.assert(!define.equal(uses));
        try defineNodeIfDoesntExist(igraph, define, allocator);
        try igraph.nodes.getPtr(define).?.moves.put(uses, {});
        try defineNodeIfDoesntExist(igraph, uses, allocator);
        try igraph.nodes.getPtr(uses).?.moves.put(define, {});
    }
}

fn defineNodeIfDoesntExist(graph: *IGraph, val: parser.Operand, allocator: std.mem.Allocator) !void {
    if (!graph.nodes.contains(val)) {
        try graph.nodes.put(val, Node.init(val, allocator));
    }
}
