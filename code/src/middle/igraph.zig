const std = @import("std");
const parser = @import("parse.zig");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;
const Line = @import("common").alloc.AllocLine;
const Operand = @import("common").alloc.Operand;

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

    pub fn deinit(self: *@This()) void {
        self.neighbors.deinit();
        self.moves.deinit();
    }
};

pub const IGraph = struct {
    nodes: std.AutoHashMap(Operand, Node),
    aliases: std.AutoHashMap(Operand, Operand),

    pub fn init(alloc: Allocator) @This() {
        return IGraph{
            .aliases = std.AutoHashMap(Operand, Operand).init(alloc),
            .nodes = std.AutoHashMap(Operand, Node).init(alloc),
        };
    }

    pub fn deinit(self: *@This()) void {
        {
            var it = self.nodes.valueIterator();
            while (it.next()) |n| {
                n.deinit();
            }
            self.nodes.deinit();
        }
        self.aliases.deinit();
    }

    pub fn print(self: *@This(), allocator: Allocator, writer: Writer) !void {
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
    pub fn mergeNodes(self: *@This(), dst: Operand, src: Operand) !void {
        var dst_node = self.nodes.getPtr(dst) orelse {
            return error.IllegalGraph;
        };
        var src_node = self.nodes.getPtr(src) orelse {
            return error.IllegalGraph;
        };

        {
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

        {
            // loop other nodes looking for merged node
            var it = self.nodes.iterator();
            while (it.next()) |key| {
                const node = key.value_ptr;

                // fix nbors
                if (node.neighbors.contains(src)) {
                    _ = node.neighbors.remove(src);
                    // prevent self reflection
                    if (!node.val.equal(dst)) {
                        _ = try node.neighbors.put(dst, {});
                    }
                }
                // fix moves
                if (node.moves.contains(src)) {
                    _ = node.moves.remove(src);
                    // prevent self reflection
                    if (!node.val.equal(dst)) {
                        _ = try node.moves.put(dst, {});
                    }
                }
            }
        }
        // setup aliases
        try self.aliases.put(src, dst);
        // free
        src_node.deinit();
        _ = self.nodes.remove(src);
    }

    pub fn resolveAlias(self: *@This(), op: Operand) Operand {
        var cur = op;
        while (self.aliases.get(cur)) |found| {
            cur = found;
        }
        return cur;
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
    var it = line.defines.ops.keyIterator();
    while (it.next()) |define_op| {
        var live_out_it = line.live_out.ops.keyIterator();
        while (live_out_it.next()) |live_out_op| {
            // skip memory or special registers
            if (define_op.* == .mem or live_out_op.* == .mem or define_op.* == .spec_reg or live_out_op.* == .spec_reg) {
                continue;
            }
            try defineNodeIfDoesntExist(igraph, define_op.*, allocator);
            // build graph
            if (!Operand.equal(define_op.*, live_out_op.*)) {
                std.debug.assert(igraph.nodes.contains(live_out_op.*));
                std.debug.assert(igraph.nodes.contains(define_op.*));
                try igraph.nodes.getPtr(define_op.*).?.neighbors.put(live_out_op.*, {});
                igraph.nodes.getPtr(define_op.*).?.static_degree += 1;
                igraph.nodes.getPtr(define_op.*).?.cur_degree += 1;
                try igraph.nodes.getPtr(live_out_op.*).?.neighbors.put(define_op.*, {});
                igraph.nodes.getPtr(live_out_op.*).?.static_degree += 1;
                igraph.nodes.getPtr(live_out_op.*).?.cur_degree += 1;
            }
        }
    }
    // keep track of moves
    if (line.move) {
        std.debug.assert(line.defines.ops.count() == 1);
        std.debug.assert(line.uses.ops.count() == 1);
        const define = try line.defines.single();
        const uses = try line.uses.single();

        if (define == .mem or uses == .mem) {
            return;
        }

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

// nodes: A, B, C
// A <-> B <- C
// :call: merge(A, B)
// result: A <- C
test "coalesce removes stale move refs" {
    const alloc = std.testing.allocator;
    var graph = IGraph.init(alloc);
    defer graph.deinit();
    const a = Operand{ .temp = 0 };
    const b = Operand{ .temp = 1 };
    const c = Operand{ .temp = 2 };
    // init nodes
    try graph.nodes.put(a, Node.init(a, alloc));
    try graph.nodes.put(b, Node.init(b, alloc));
    try graph.nodes.put(c, Node.init(c, alloc));
    // establish moves
    try graph.nodes.getPtr(a).?.moves.put(b, {});
    try graph.nodes.getPtr(b).?.moves.put(a, {});
    try graph.nodes.getPtr(c).?.moves.put(b, {});

    try graph.mergeNodes(a, b);

    try std.testing.expectEqual(2, graph.nodes.count());
    // assert B is gone
    if (graph.nodes.contains(b)) {
        return error.MergeFailed;
    }
    // assert A <- ...
    const a_node = graph.nodes.getPtr(a) orelse return error.CantFindA;
    try std.testing.expectEqual(0, a_node.moves.count());
    // assert C -> A
    const c_node = graph.nodes.getPtr(c) orelse return error.CantFindA;
    try std.testing.expectEqual(1, c_node.moves.count());
    try std.testing.expect(c_node.moves.contains(a));
}
