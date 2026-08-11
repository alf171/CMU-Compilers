const std = @import("std");
const parser = @import("parse.zig");
const RegisterFile = @import("common").register.RegisterFile;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;
const Line = @import("common").alloc.AllocLine;
const Operand = @import("common").alloc.Operand;
const RegisterClass = @import("common").register.RegisterClass;

const DegreeCount = u16;

pub const Node = struct {
    val: Operand,
    reg_class: RegisterClass,
    neighbors: std.AutoHashMap(Operand, void),
    moves: std.AutoHashMap(Operand, void),
    selected: bool = false,
    static_degree: DegreeCount = 0,
    cur_degree: DegreeCount = 0,
    /// utilize to select which temp to spill
    spill_cost: u32 = 0,
    /// encode which colors aren't allowed. ultimately, we should have a precoloring stage to avoid this hack
    forbidden_colors: u32 = 0,

    pub fn init(val: Operand, reg_class: RegisterClass, allocator: Allocator) Node {
        return Node{
            .val = val,
            .reg_class = reg_class,
            .neighbors = std.AutoHashMap(Operand, void).init(allocator),
            .moves = std.AutoHashMap(Operand, void).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.neighbors.deinit();
        self.moves.deinit();
    }

    pub fn placeNode(self: *@This(), operand: Operand) !void {
        const result = try self.neighbors.getOrPut(operand);
        if (result.found_existing) return;

        self.static_degree += 1;
        self.cur_degree += 1;
    }

    /// how many colors are available to this node
    pub fn legalCount(self: @This(), k: u16) DegreeCount {
        // largest value forbidden_colors supports
        std.debug.assert(k < 32);
        const mask = (@as(u32, 1) << @intCast(k)) - 1;
        const forbiddden_count: DegreeCount = @popCount(mask & self.forbidden_colors);

        return k - forbiddden_count;
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

    pub fn defineNodeIfDoesntExist(graph: *IGraph, val: Operand, reg_class: RegisterClass, allocator: Allocator) !void {
        if (graph.nodes.getPtr(val)) |node| {
            std.debug.assert(node.reg_class.type == reg_class.type);
            std.debug.assert(node.reg_class.width == reg_class.width);
            return;
        }
        if (!graph.nodes.contains(val)) {
            try graph.nodes.put(val, Node.init(val, reg_class, allocator));
        }
    }

    pub fn addInterference(
        self: *@This(),
        a: Operand,
        b: Operand,
        a_class: RegisterClass,
        b_class: RegisterClass,
        alloc: std.mem.Allocator,
    ) !void {
        if (Operand.equal(a, b)) return;

        switch (a) {
            .mem => return,
            .reg => |reg| switch (b) {
                .reg, .mem => return,
                .temp => {
                    try defineNodeIfDoesntExist(self, b, b_class, alloc);
                    std.debug.assert(self.nodes.contains(b));
                    for (0..reg.width) |offset| {
                        const id = @as(usize, reg.id) + offset;
                        self.nodes.getPtr(b).?.forbidden_colors |= (@as(u32, 1) << @intCast(id));
                    }
                    return;
                },
                .unknown => return error.BadState,
            },
            .temp => switch (b) {
                .temp => {
                    try defineNodeIfDoesntExist(self, a, a_class, alloc);
                    try defineNodeIfDoesntExist(self, b, b_class, alloc);
                    std.debug.assert(self.nodes.contains(a));
                    std.debug.assert(self.nodes.contains(b));
                    try self.nodes.getPtr(a).?.placeNode(b);
                    try self.nodes.getPtr(b).?.placeNode(a);
                    return;
                },
                .reg => |reg| {
                    try defineNodeIfDoesntExist(self, a, a_class, alloc);
                    std.debug.assert(self.nodes.contains(a));
                    for (0..reg.width) |offset| {
                        const id: usize = reg.id + offset;
                        self.nodes.getPtr(a).?.forbidden_colors |= (@as(u32, 1) << @intCast(id));
                    }
                    return;
                },
                .mem => return,
                .unknown => return error.BadState,
            },
            .unknown => return error.BadState,
        }
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
            dst_node.spill_cost += src_node.spill_cost;
            // do we have sleeper nodes like mem and special?
            const degree: u8 = @intCast(dst_node.neighbors.count());
            dst_node.cur_degree = degree;
            dst_node.static_degree = degree;
            dst_node.forbidden_colors |= src_node.forbidden_colors;
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

pub fn createIgraph(lines: ArrayList(Line), register_file: RegisterFile, allocator: Allocator) !IGraph {
    var igraph = IGraph.init(allocator);
    for (lines.items) |line| {
        try placeNodes(&igraph, line, register_file, allocator);
    }
    return igraph;
}

fn placeNodes(
    igraph: *IGraph,
    line: Line,
    register_file: RegisterFile,
    allocator: Allocator,
) !void {
    // place all defines
    {
        var it = line.defines.ops.iterator();
        while (it.next()) |entry| {
            const op = entry.key_ptr.*;
            const reg_class = entry.value_ptr.*;

            if (reg_class.type != register_file.type) continue;
            if (!op.shouldColor()) continue;

            try igraph.defineNodeIfDoesntExist(op, reg_class, allocator);
            igraph.nodes.getPtr(op).?.spill_cost += 1;
        }
    }
    // place all uses
    {
        var it = line.uses.ops.iterator();
        while (it.next()) |entry| {
            const op = entry.key_ptr.*;
            const reg_class = entry.value_ptr.*;

            if (reg_class.type != register_file.type) continue;
            if (!op.shouldColor()) continue;

            try igraph.defineNodeIfDoesntExist(op, reg_class, allocator);
            igraph.nodes.getPtr(op).?.spill_cost += 1;
        }
    }
    // temporary clobbering logic
    {
        if (line.clobber_caller_saved) {
            var it = line.live_out.ops.iterator();
            while (it.next()) |entry| {
                const op = entry.key_ptr.*;
                const reg_class = entry.value_ptr.*;

                if (reg_class.type != register_file.type) continue;
                if (!op.shouldColor()) continue;
                // x <- f(y) scenario, x can be a caller-safe register in this scenario
                if (line.defines.ops.contains(op)) continue;

                try igraph.defineNodeIfDoesntExist(op, reg_class, allocator);
                igraph.nodes.getPtr(op).?.forbidden_colors |= register_file.forbidden_mask;
            }
        }
    }
    // build interference edges
    {
        var it = line.defines.ops.iterator();
        while (it.next()) |define_entry| {
            if (define_entry.value_ptr.*.type != register_file.type) continue;

            const define_op = define_entry.key_ptr.*;
            const define_class = define_entry.value_ptr.*;
            var live_out_it = line.live_out.ops.iterator();
            while (live_out_it.next()) |live_out_entry| {
                const live_out_class = live_out_entry.value_ptr.*;
                if (live_out_class.type != register_file.type) continue;

                const live_out_op = live_out_entry.key_ptr.*;
                try igraph.addInterference(define_op, live_out_op, define_class, live_out_class, allocator);
            }
        }
    }
    // things used together should interfer also
    {
        var use_it = line.uses.ops.iterator();
        while (use_it.next()) |first_entry| {
            const first_op = first_entry.key_ptr.*;
            const first_class = first_entry.value_ptr.*;
            if (first_entry.value_ptr.*.type != register_file.type) continue;

            var use_it_2 = line.uses.ops.iterator();
            while (use_it_2.next()) |second_entry| {
                const second_op = second_entry.key_ptr.*;
                const second_class = second_entry.value_ptr.*;
                if (second_class.type != register_file.type) continue;

                try igraph.addInterference(first_op, second_op, first_class, second_class, allocator);
            }
        }
    }
    // keep track of moves
    {
        if (line.move) {
            const define = try line.defines.singleForType(register_file.type) orelse return;
            const uses = try line.uses.singleForType(register_file.type) orelse return;

            const define_class = line.defines.ops.get(define).?;
            const uses_class = line.uses.ops.get(uses).?;

            // skip memory and register things from coalescing.
            if (define == .mem or uses == .mem or define == .reg or uses == .reg) {
                return;
            }

            if (define_class.width != uses_class.width) return;
            if (define.equal(uses)) return;

            try igraph.defineNodeIfDoesntExist(define, define_class, allocator);
            try igraph.nodes.getPtr(define).?.moves.put(uses, {});
            try igraph.defineNodeIfDoesntExist(uses, uses_class, allocator);
            try igraph.nodes.getPtr(uses).?.moves.put(define, {});
        }
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
    const a = Operand{ .temp = .{ .id = 0, .function_id = 0 } };
    const b = Operand{ .temp = .{ .id = 1, .function_id = 0 } };
    const c = Operand{ .temp = .{ .id = 2, .function_id = 0 } };
    // init nodes
    try graph.nodes.put(a, Node.init(a, .{ .type = .gp, .width = 1 }, alloc));
    try graph.nodes.put(b, Node.init(b, .{ .type = .gp, .width = 1 }, alloc));
    try graph.nodes.put(c, Node.init(c, .{ .type = .gp, .width = 1 }, alloc));
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
