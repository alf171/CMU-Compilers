// goal of this file is to go from interference graph to a colored inteference graph
const std = @import("std");
const parser = @import("parse.zig");
const graph = @import("igraph.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const RegisterFile = @import("common").register.RegisterFile;
const Operand = @import("common").alloc.Operand;

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
    forbidden_colors: u32 = 0,

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
    pub fn init(input: *graph.IGraph, allocator: Allocator) !@This() {
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
            const moved_node = Node{
                .moves = moves,
                .neighbors = neighbors,
                .val = node_ptr.val,
                .forbidden_colors = node_ptr.forbidden_colors,
            };
            try cg.nodes.put(key, ColoredNode{
                .node = moved_node,
                .register = null,
            });
        }
        return cg;
    }

    pub fn initEmpty(alloc: std.mem.Allocator) @This() {
        return .{
            .nodes = std.AutoHashMap(Operand, ColoredNode).init(alloc),
        };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |cn| {
            cn.node.moves.deinit();
            cn.node.neighbors.deinit();
        }
        self.nodes.deinit();
    }

    pub fn absorb(self: *@This(), other: *@This()) !void {
        // ensure we have enough space to aovid partial failures
        try self.nodes.ensureUnusedCapacity(other.nodes.count());

        var other_it = other.nodes.iterator();
        while (other_it.next()) |other_entry| {
            try self.nodes.put(
                other_entry.key_ptr.*,
                other_entry.value_ptr.*,
            );
        }
        other.nodes.clearRetainingCapacity();
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
pub fn colorGraph(input: *graph.IGraph, register_file: RegisterFile, allocator: Allocator) !ColorGraphAttempt {
    // things to keep track of
    var simplify = Set(Operand).init(allocator);
    var spill = Set(Operand).init(allocator);
    defer {
        simplify.deinit();
        spill.deinit();
    }

    // phase 1, build simplify and spill
    {
        var it = input.nodes.iterator();
        while (it.next()) |ptr| {
            const node = ptr.value_ptr;

            // skip already seen nodes, pre allocated registers, and spilled registers
            if (node.selected or node.val == .reg or node.val == .mem) {
                continue;
            }

            if (node.cur_degree < node.legalCount(register_file.count)) {
                try simplify.put(node.val, {});
            } else {
                try spill.put(node.val, {});
            }
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
                try removeNode(input, node.*, &select, &simplify, &spill, register_file.count);
            }
        } else {
            // spill node with lowest impact according to our hueristic
            const id = try takeNodeWithCheapestSpill(input.nodes, &spill, allocator);
            // const node = input.nodes.get(id) orelse return error.CantFindNode;
            // const name = try id.toString(allocator);
            // defer allocator.free(name);
            // std.debug.print(
            //     "select {s} spill {s}: cost={d} degree={d} forbidden=0x{x} legal={d}/{d}\n",
            //     .{
            //         @tagName(register_file.type),
            //         name,
            //         node.spill_cost,
            //         node.static_degree,
            //         node.forbidden_colors,
            //         node.legalCount(register_file.count),
            //         register_file.count,
            //     },
            // );
            new_graph.deinit();
            return .{ .spill_register = id };
        }
    }

    // phase 3: select + color
    while (select.items.len > 0) {
        const id = select.pop().?;
        var graph_node = new_graph.nodes.getPtr(id) orelse {
            std.debug.print("node doesn't exist in graph", .{});
            return error.GraphError;
        };

        const reg = try scanForRegister(graph_node, &new_graph, register_file.count) orelse {
            const str = try id.toString(allocator);
            defer allocator.free(str);
            std.debug.print("couldn't find register for {s}\n", .{str});
            new_graph.deinit();
            return .{ .spill_register = id };
        };
        graph_node.register = reg;
    }

    // phase 4: swap Operand aliases
    {
        var it = input.aliases.iterator();
        while (it.next()) |key| {
            const old = key.key_ptr.*;
            const new = input.resolveAlias(key.value_ptr.*);

            const rep_colors = new_graph.nodes.get(new) orelse return error.CantFindAlias;
            const reg = rep_colors.register orelse return error.MissingColor;

            try new_graph.nodes.put(old, .{
                // this doesn't matter at this point
                .node = .{
                    .moves = Set(Operand).init(allocator),
                    .neighbors = Set(Operand).init(allocator),
                    .val = old,
                },
                .register = reg,
            });
        }
    }

    return .{ .graph = new_graph };
}

/// build our select stack. move things between simplify and spill as needed
fn removeNode(input: *const graph.IGraph, node: graph.Node, select: *std.array_list.Managed(Operand), simplify: *Set(Operand), spill: *Set(Operand), register_count: u16) !void {
    std.debug.assert(node.val != .reg);
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

        if (n.selected or n.val == .reg or n.val == .mem) {
            continue;
        }

        // if we go from k -> k - 1, move from spill to select
        if (n.cur_degree == n.legalCount(register_count)) {
            std.debug.assert(spill.contains(n_ptr.*));
            std.debug.assert(!simplify.contains(n_ptr.*));
            _ = spill.remove(n_ptr.*);
            _ = try simplify.put(n_ptr.*, {});
        }
        n.cur_degree -= 1;
    }
}

// spill cost / degree
fn takeNodeWithCheapestSpill(
    input_graph: std.AutoHashMap(Operand, graph.Node),
    canadidites: *std.AutoHashMap(Operand, void),
    allocator: std.mem.Allocator,
) !Operand {
    var it = canadidites.keyIterator();
    var best_id: ?Operand = null;
    var best_cost: u32 = 0;
    var best_degree: u16 = 1;

    while (it.next()) |canadidite| {
        const name = try canadidite.*.toString(allocator);
        const node = input_graph.get(canadidite.*) orelse continue;
        defer allocator.free(name);

        const degree = @max(node.static_degree, 1);
        // base case
        if (best_id == null) {
            best_id = canadidite.*;
            best_degree = degree;
            best_cost = node.spill_cost;
            continue;
        }
        // cross product to change to multiplies
        const candidate_score: u64 = @as(u64, node.spill_cost) * @as(u64, best_degree);
        const best_score: u64 = @as(u64, best_cost) * @as(u64, degree);
        if (candidate_score < best_score) {
            best_id = canadidite.*;
            best_degree = degree;
            best_cost = node.spill_cost;
        }
    }
    const id = best_id orelse return error.IllegalGraph;
    const selected_name = try id.toString(allocator);
    defer allocator.free(selected_name);
    _ = canadidites.remove(id);
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
// skip registers based on callee_save_mask
fn scanForRegister(cnode: *ColoredNode, g: *ColoredGraph, k: u16) !?u8 {
    std.debug.assert(cnode.register == null);
    scan: for (0..k) |scan_reg| {
        // bit mask skip logic
        if (cnode.node.forbidden_colors & (@as(u32, 1) << @intCast(scan_reg)) != 0) {
            continue :scan;
        }
        // selection logic
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
