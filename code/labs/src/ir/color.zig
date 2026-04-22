// goal of this file is to go from interference graph to a colored inteference graph
const std = @import("std");
const parser = @import("parse.zig");
const graph = @import("igraph.zig");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;
const Operands = parser.Operands;
const Operand = parser.Operand;

pub fn Set(comptime K: type) type {
    return std.AutoHashMap(K, void);
}

// TODO: hacky way to have different nodes
pub const Node = struct {
    // TODO: consider value of duplicate term
    // allows us to make our key in our maps smaller i.e. us a NodeId of some sort :)
    val: Operand,
    neighbors: Set(Operand),
    moves: Set(Operand),

    pub fn init(val: Operand, allocator: Allocator) Node {
        return Node{ .val = val, .neighbors = Set(Operand).init(allocator), .moves = Set(Operand).init(allocator) };
    }

    pub fn deinit(self: *@This()) void {
        self.moves.deinit();
    }
};

pub const ColoredNode = struct {
    node: Node,
    register: ?u8,
};

pub const ColoredGraph = struct {
    nodes: std.AutoHashMap(Operand, ColoredNode),

    // compose a node with a register since we need it for coloring
    pub fn init(input: *graph.IGraph, allocator: Allocator) !ColoredGraph {
        var cg = ColoredGraph{
            .nodes = std.AutoHashMap(Operand, ColoredNode).init(allocator),
        };
        var it = input.nodes.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            var node_ptr = entry.value_ptr;

            var neighbors = try node_ptr.neighbors.clone();
            errdefer neighbors.deinit();
            var moves = try node_ptr.moves.clone();
            errdefer moves.deinit();

            // hacky way to have different nodes
            // TODO: consider sharing memory between igraph and ColoredGraph to avoid cloning memory
            const moved_node = Node{ .moves = moves, .neighbors = neighbors, .val = node_ptr.val };
            try cg.nodes.put(key, ColoredNode{
                .node = moved_node,
                .register = null,
            });
        }
        return cg;
    }

    pub fn deinit(self: *@This()) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |cn| {
            cn.node.moves.deinit();
            cn.node.neighbors.deinit();
        }
        self.nodes.deinit();
    }

    pub fn print(self: *@This(), allocator: Allocator, stdout: *Writer) !void {
        try stdout.print("colored graph: [register] temp -> interfer temp/s\n", .{});
        var it = self.nodes.iterator();
        while (it.next()) |node_ptr| {
            const key_str = try node_ptr.key_ptr.*.toString(allocator);
            defer allocator.free(key_str);
            const value = node_ptr.value_ptr.*;

            var buf = std.array_list.Managed(u8).init(allocator);
            var inner_it = value.node.neighbors.iterator();
            const reg = value.register;
            var i: usize = 0;
            while (inner_it.next()) |value_ptr| : (i += 1) {
                const str = try value_ptr.key_ptr.toString(allocator);
                defer allocator.free(str);
                try buf.appendSlice(str);
                if (i + 1 != value.node.neighbors.count()) {
                    try buf.appendSlice(", ");
                }
            }

            try stdout.print("[{?d}] {s} -> ({s})\n", .{ reg, key_str, buf.items });
            try stdout.flush();
            defer buf.deinit();
        }
    }
};

const ColorGraphAttempt = union(enum) { graph: ColoredGraph, spill_register: Operand };

/// color a graph and generate a new graph via spilling if needed
/// at what layer of abstraction should we do all of this is still being decided
/// could consider doing this in src/main.zig
/// main things left to be done
/// 1. implement spilling with no heuristic
/// 2. color special register following TODO in code
/// 3. implement coalescing
/// 4. add heuristic for spilling
/// 5. clean up any code / todos
pub fn colorGraph(input: *graph.IGraph, k: u8, allocator: Allocator) !ColorGraphAttempt {
    // things to keep track of
    var simplify = Set(Operand).init(allocator);
    var spill = Set(Operand).init(allocator);
    defer {
        simplify.deinit();
        spill.deinit();
    }

    // phase 1, build simplify and spill
    var it = input.nodes.iterator();
    while (it.next()) |ptr| {
        const node = ptr.value_ptr;

        // skip already seen nodes, special registers, and spilled registers
        if (node.selected or node.val == .spec_reg or node.val == .mem) {
            continue;
        }

        if (node.cur_degree < k) {
            try simplify.put(node.val, {});
        } else {
            try spill.put(node.val, {});
        }
    }

    var new_graph = try ColoredGraph.init(input, allocator);
    // TODO: run tiny pass coloring all nodes which have a spec_reg

    // TODO: consider presizing stack since we have some knowledge at runtime
    var select = std.array_list.Managed(Operand).init(allocator);
    defer select.deinit();

    // phase 2: build select
    while (simplify.count() > 0 or spill.count() > 0) {
        if (simplify.count() > 0) {
            const id = try takeAny(&simplify);
            const node = input.nodes.getPtr(id) orelse {
                return error.CantFindNode;
            };
            if (!node.selected) {
                try removeNode(input, node.*, &select, &simplify, &spill, k);
                node.spill = false;
            }
        } else {
            // spill node with most edges
            const id = try takeNodeWithMostEdges(input.nodes, &spill);
            const node = input.nodes.getPtr(id) orelse {
                return error.CantFindNode;
            };
            if (!node.selected) {
                try removeNode(input, node.*, &select, &simplify, &spill, k);
                node.spill = true;
            }
        }
    }

    // phase 3: select + color
    while (select.items.len > 0) {
        const id = select.pop().?;
        const node = input.nodes.getPtr(id) orelse {
            std.debug.print("node doesn't exist in graph", .{});
            return error.GraphError;
        };
        var graph_node = new_graph.nodes.getPtr(id) orelse {
            std.debug.print("node doesn't exist in graph", .{});
            return error.GraphError;
        };

        if (!node.spill) {
            const str = try id.toString(allocator);
            defer allocator.free(str);
            // std.debug.print("simplifying {s}\n", .{str});
            const reg = try scanForRegister(graph_node, &new_graph, k) orelse {
                std.debug.print("couldn't find register for {s}\n", .{str});
                try spill.put(id, {});
                continue;
            };
            // std.debug.print("assigning reg for {s}\n", .{str});
            graph_node.register = reg;
        } else {
            const str = try id.toString(allocator);
            defer allocator.free(str);
            // std.debug.print("spilling reg for {s}\n", .{str});
            new_graph.deinit();
            return .{ .spill_register = id };
        }
    }

    return .{ .graph = new_graph };
}

/// build our select stack. move things between simplify and spill as needed
fn removeNode(input: *const graph.IGraph, node: graph.Node, select: *std.array_list.Managed(Operand), simplify: *Set(Operand), spill: *Set(Operand), k: u8) !void {
    std.debug.assert(node.val != .spec_reg);
    std.debug.assert(!node.selected);
    try select.append(node.val);
    const item = input.nodes.getPtr(node.val).?;
    item.selected = true;

    // dec nbors
    var n_bor = node.neighbors.keyIterator();
    while (n_bor.next()) |n_ptr| {
        const n = input.nodes.getPtr(n_ptr.*) orelse {
            std.log.debug("cant find nbor node", .{});
            return error.CantFindNode;
        };

        if (n.selected or n.val == .spec_reg or n.val == .mem) {
            continue;
        }

        // if we go from k -> k - 1, move from spill to select
        if (n.cur_degree == k) {
            std.debug.assert(spill.contains(n_ptr.*));
            std.debug.assert(!simplify.contains(n_ptr.*));
            _ = spill.remove(n_ptr.*);
            _ = try simplify.put(n_ptr.*, {});
        }
        n.cur_degree -= 1;
    }
}

fn takeNodeWithMostEdges(input_graph: std.AutoHashMap(Operand, graph.Node), s: *std.AutoHashMap(Operand, void)) !Operand {
    var it = s.keyIterator();
    var best_id: ?Operand = null;
    var max_edges: u32 = 0;
    while (it.next()) |p| {
        const temp = p.*;
        const node = input_graph.get(temp) orelse continue;
        const edges = node.neighbors.count();
        if (edges > max_edges) {
            max_edges = node.neighbors.count();
            best_id = temp;
        }
    }
    const id = best_id orelse return error.IllegalGraph;
    _ = s.remove(id);
    return id;
}

/// remove a node from map and return it to the caller
/// this fun is not fun is not deterministic
fn takeAny(s: *std.AutoHashMap(Operand, void)) !Operand {
    var it = s.keyIterator();
    if (it.next()) |p| {
        const id = p.*;
        _ = s.remove(id);
        return id;
    }
    return error.IllegalGraph;
}

// take a node. determininstically find lowest reg available
fn scanForRegister(cnode: *ColoredNode, g: *ColoredGraph, k: u8) !?u8 {
    std.debug.assert(cnode.register == null);
    scan: for (0..k) |scan_reg| {
        var it = cnode.node.neighbors.keyIterator();
        while (it.next()) |key| {
            const nbor = g.nodes.get(key.*) orelse {
                std.debug.print("cant find node for register", .{});
                return error.GraphError;
            };
            const nbor_reg = nbor.register orelse {
                continue;
            };
            if (nbor_reg == scan_reg) {
                continue :scan;
            }
        }
        return @intCast(scan_reg);
    }
    return null;
}
