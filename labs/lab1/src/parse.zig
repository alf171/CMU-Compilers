const std = @import("std");

pub const SpecialRegs = enum { eax };
const SpecRegsMap = std.StaticStringMap(SpecialRegs);
const spec_reg_map = SpecRegsMap.initComptime(.{
    .{ "eax", .eax },
});

pub const Operand = union(enum) {
    // 256 temps are possible currently
    temp: u8,
    spec_reg: SpecialRegs,
    mem: u8,

    pub fn equal(self: Operand, other: Operand) bool {
        return switch (self) {
            .temp => |t1| switch (other) {
                .temp => |t2| t1 == t2,
                else => false,
            },
            .spec_reg => |t1| switch (other) {
                .spec_reg => |t2| return t1 == t2,
                else => false,
            },
            .mem => |t1| switch (other) {
                .mem => |t2| return t1 == t2,
                else => false,
            },
        };
    }

    pub fn toString(op: Operand, allocator: std.mem.Allocator) ![]u8 {
        return switch (op) {
            .temp => |t| std.fmt.allocPrint(allocator, "%t{d}", .{t + 1}),
            .spec_reg => |s| std.fmt.allocPrint(allocator, "%{s}", .{@tagName(s)}),
            .mem => |t| std.fmt.allocPrint(allocator, "spill{d}", .{t + 1}),
        };
    }
    pub fn print(op: Operand, stdout: *std.io.Writer) !void {
        switch (op) {
            .temp => |t| try stdout.print("%t{d}", .{t + 1}),
            .spec_reg => |s| try stdout.print("%{s}", .{@tagName(s)}),
            .mem => |t| try stdout.print("spill{d}", .{t + 1}),
        }
    }
};

pub const Operands = struct {
    ops: std.array_list.Managed(Operand),

    pub fn toJoinedString(self: Operands, allocator: std.mem.Allocator) ![]u8 {
        var list = std.array_list.Managed(u8).init(allocator);
        errdefer list.deinit();

        var first = true;
        for (self.ops.items) |op| {
            if (!first) try list.appendSlice(", ") else first = false;
            const s = try op.toString(allocator);
            defer allocator.free(s);
            try list.appendSlice(s);
        }
        return list.toOwnedSlice();
    }

    pub fn contains(self: Operands, op: Operand) bool {
        for (self.ops.items) |self_op| {
            if (Operand.equal(self_op, op)) {
                return true;
            }
        }
        return false;
    }

    /// return a new Operand removing op
    /// requires the elements being removed to be present
    pub fn remove(self: Operands, op: Operand, allocator: std.mem.Allocator) !Operands {
        std.debug.assert(self.contains(op));
        var ops = std.array_list.Managed(Operand).init(allocator);
        for (self.ops.items) |loop_op| {
            if (!loop_op.equal(op)) {
                try ops.append(loop_op);
            }
        }
        return Operands{ .ops = ops };
    }

    pub fn clone(self: Operands, allocator: std.mem.Allocator) !Operands {
        var new = Operands.init(allocator);
        for (self.ops.items) |item| {
            try new.ops.append(item);
        }
        return new;
    }

    pub fn init(allocator: std.mem.Allocator) Operands {
        const ops = std.array_list.Managed(Operand).init(allocator);
        return Operands{ .ops = ops };
    }

    pub fn free(self: Operands) void {
        self.ops.deinit();
    }
};

const RawLine = struct {
    Uses: [][]const u8,
    Defines: [][]const u8,
    Live_out: [][]const u8,
    Move: bool,
    Line: i32,
};

pub const Line = struct {
    uses: Operands,
    defines: Operands,
    live_out: Operands,
    move: bool,
    line_number: i32,

    pub fn deinit(self: *Line) void {
        self.uses.free();
        self.defines.free();
        self.live_out.free();
    }
};

/// keep track of the largest temp currently used to easy implement spilling
pub const Program = struct {
    /// how many registers the program needs to utilize
    register_count: u8,
    /// the raw lines being passed into the program
    lines: std.array_list.Managed(Line),
    /// keep track of largest temp used in program
    max_temp_reg: u8,
    /// keep track of memory uses
    mem_pointer: u8,

    pub fn print(program: Program, stdout: *std.io.Writer) !void {
        try stdout.print("register count: {d}\n", .{program.register_count});

        for (program.lines.items) |line| {
            try stdout.print("[{d}] ", .{line.line_number});
            if (line.defines.ops.items.len == 0) {
                try stdout.print("_ <- ", .{});
            } else {
                // assume we only define a single temp
                try line.defines.ops.items[0].print(stdout);
                try stdout.print(" <- ", .{});
            }
            if (line.uses.ops.items.len > 0) {
                try stdout.print("op(", .{});
                for (line.uses.ops.items, 0..) |use, i| {
                    try use.print(stdout);
                    // if not last element
                    if (i + 1 != line.uses.ops.items.len) {
                        try stdout.print(", ", .{});
                    }
                }
                try stdout.print(")", .{});
            } else {
                try stdout.print("_", .{});
            }

            // print spill info
            try stdout.print(" [", .{});
            for (line.live_out.ops.items, 0..) |live_out, i| {
                if (i != 0) {
                    try stdout.print("", .{});
                }
                try live_out.print(stdout);
                if (i + 1 != line.live_out.ops.items.len) {
                    try stdout.print(", ", .{});
                }
            }
            try stdout.print("]", .{});
            try stdout.print("\n", .{});
        }
        try stdout.flush();
    }

    pub fn deinit(program: Program) void {
        for (program.lines.items) |*line| {
            line.deinit();
        }
        program.lines.deinit();
    }
};

fn parse_temp_reg(s: []const u8) !Operand {
    if (s.len > 2 and s[0] == '%' and s[1] == 't') {
        const n = try std.fmt.parseInt(u8, s[2..], 10);
        return .{ .temp = n - 1 };
    }
    if (s.len > 1 and s[0] == '%') {
        if (spec_reg_map.get(s[1..])) |pr| {
            return .{ .spec_reg = pr };
        }
    }

    return error.UnkownRegister;
}

fn parse_temp_reg_list(alloctor: std.mem.Allocator, ss: [][]const u8) !Operands {
    var count: usize = 0;
    for (ss) |_| {
        count += 1;
    }

    var res = Operands.init(alloctor);
    errdefer res.free();

    for (ss) |s| {
        const out_val = try parse_temp_reg(s);
        try res.ops.append(out_val);
    }
    return res;
}

/// Go from file_name -> data struct to test our compiler
/// within this middle step of the compiler
pub fn parse(filename: []const u8, allocator: std.mem.Allocator) !Program {
    std.debug.print("Got filename: {s}\n", .{filename});
    const file = try std.fs.cwd().openFile(filename, .{
        .mode = .read_only,
    });
    defer file.close();

    // cap read to 1 MiB; adjust as needed
    const bytes = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(bytes);

    // Find the delim line //target
    const delim = "//target";
    const dpos = std.mem.indexOf(u8, bytes, delim) orelse {
        std.debug.print("No //target found ", .{});
        return error.SyntaxError;
    };

    // advance after target
    var after: []const u8 = bytes[dpos + delim.len ..];

    // skip spaces/tabs
    after = std.mem.trimLeft(u8, after, " \t");

    // take remaining of line
    const nl = std.mem.indexOfScalar(u8, after, '\n') orelse return error.SyntaxError;
    const num_str = std.mem.trim(u8, after[0..nl], " \t");
    const reg_count = try std.fmt.parseInt(u8, num_str, 10);
    after = after[nl + 1 ..];

    const start = std.mem.indexOfScalar(u8, after, '[') orelse return error.SyntaxError;
    const json_src = after[start..];
    // std.debug.print("JSON slice (first 200):\n{s}\n", .{json_src[0..@min(json_src.len, 200)]});

    const parsed = try std.json.parseFromSlice([]RawLine, allocator, json_src, .{});
    defer parsed.deinit();

    var lines = std.array_list.Managed(Line).init(allocator);
    var filled: usize = 0;
    errdefer {
        var k: usize = 0;
        while (k < filled) : (k += 1) {
            lines.items[k].deinit();
        }
        lines.deinit();
    }
    var max_temp_reg: u8 = 0;
    for (parsed.value, 0..) |raw_line, i| {
        try lines.append(Line{
            .uses = try parse_temp_reg_list(allocator, raw_line.Uses),
            .defines = try parse_temp_reg_list(allocator, raw_line.Defines),
            .live_out = try parse_temp_reg_list(allocator, raw_line.Live_out),
            .move = raw_line.Move,
            .line_number = raw_line.Line,
        });
        filled = i + 1;
        if (lines.items[i].defines.ops.items.len > 0) {
            switch (lines.items[i].defines.ops.items[0]) {
                .temp => |v| {
                    max_temp_reg = @max(v, max_temp_reg);
                },
                else => {},
            }
        }
    }

    return Program{ .lines = lines, .register_count = reg_count, .max_temp_reg = max_temp_reg, .mem_pointer = 0 };
}
