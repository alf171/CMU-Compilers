const std = @import("std");
const parser = @import("parse.zig");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;
const Line = parser.Line;
const Operand = parser.Operand;

pub const Node = struct {
    val: Operand,
    neighbors: std.AutoHashMap(Operand, void),
    moves: std.AutoHashMap(Operand, void),
    selected: bool = false,
    spill: bool = false,
    static_degree: u8 = 0,
    cur_degree: u8 = 0,

    pub fn init(val: Operand, allocator: Allocator) Node {
        return Node{ .val = val, .neighbors = std.AutoHashMap(Operand, void).init(allocator), .moves = std.AutoHashMap(Operand, void).init(allocator) };
    }

    pub fn deinit(self: *Node) void {
        self.neighbors.deinit();
        self.moves.deinit();
    }
};

pub const IGraph = struct {
    nodes: std.AutoHashMap(Operand, Node),

    pub fn init(allocator: Allocator) IGraph {
        return IGraph{ .nodes = std.AutoHashMap(Operand, Node).init(allocator) };
    }

    pub fn deinit(self: *IGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            n.deinit();
        }
        self.nodes.deinit();
    }

    pub fn print(self: *IGraph, allocator: Allocator, writer: Writer) !void {
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

            writer.print("{s} -> {s}\n", .{ key_str, buf.items });
            defer buf.deinit();
        }
    }

    /// merge dst and src into a single node. dst will represent both nodes.
    /// not concerned with validility or merge just functionality.
    /// TODO: need a graph wide swap now of dst <- src
    pub fn mergeNodes(self: *IGraph, dst: Operand, src: Operand) !void {
        var dst_node = self.nodes.get(dst) orelse {
            return error.IllegalGraph;
        };
        var src_node = self.nodes.get(src) orelse {
            return error.IllegalGraph;
        };

        defer src_node.deinit();
        _ = self.nodes.remove(src);

        var it = src_node.neighbors.keyIterator();
        // union of nbors \ eachother
        while (it.next()) |k| {
            try dst_node.neighbors.put(k.*, {});
        }
        _ = dst_node.neighbors.remove(src);
        _ = dst_node.neighbors.remove(dst);

        // union of moves \ eachother
        var moves_it = src_node.moves.keyIterator();
        while (moves_it.next()) |nbor| {
            try dst_node.moves.put(nbor.*, {});
        }
        _ = dst_node.moves.remove(src);
        _ = dst_node.moves.remove(dst);

        dst_node.selected = false;
        dst_node.spill = src_node.spill or dst_node.spill;
        // do we have sleeper nodes like mem and special?
        const degree: u8 = @intCast(dst_node.neighbors.count());
        dst_node.cur_degree = degree;
        dst_node.static_degree = degree;
    }
};

pub fn createIgraph(lines: std.array_list.Managed(Line), allocator: Allocator) !IGraph {
    var igraph = IGraph.init(allocator);
    for (lines.items) |line| {
        try placeNodes(&igraph, line, allocator);
    }
    return igraph;
}

fn placeNodes(igraph: *IGraph, line: Line, allocator: Allocator) !void {
    for (line.defines.ops.items) |define_op| {
        for (line.live_out.ops.items) |live_out_op| {
            // skip memory or special registers
            if (define_op == .mem or live_out_op == .mem or define_op == .spec_reg or live_out_op == .spec_reg) {
                continue;
            }
            try defineNodeIfDoesntExist(igraph, define_op, allocator);
            // build graph
            if (!Operand.equal(define_op, live_out_op)) {
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
        std.debug.assert(line.defines.ops.items.len == 1);
        std.debug.assert(line.uses.ops.items.len == 1);
        const define = line.defines.ops.items[0];
        const uses = line.uses.ops.items[0];
        std.debug.assert(!define.equal(uses));
        try defineNodeIfDoesntExist(igraph, define, allocator);
        try igraph.nodes.getPtr(define).?.moves.put(uses, {});
        try defineNodeIfDoesntExist(igraph, uses, allocator);
        try igraph.nodes.getPtr(uses).?.moves.put(define, {});
    }
}

fn defineNodeIfDoesntExist(graph: *IGraph, val: Operand, allocator: Allocator) !void {
    if (!graph.nodes.contains(val)) {
        try graph.nodes.put(val, Node.init(val, allocator));
    }
}
