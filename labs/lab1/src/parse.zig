// goal of this file is to parse from FILE -> JSON
const std = @import("std");

pub const SpecialRegs = enum { eax };
const SpecRegsMap = std.StaticStringMap(SpecialRegs);
const spec_reg_map = SpecRegsMap.initComptime(.{
    .{ "eax", .eax },
});

pub const Operand = union(enum) {
    temp: i32,
    spec_reg: SpecialRegs,

    fn toString(op: Operand, allocator: std.mem.Allocator) ![]const u8 {
        return switch (op) {
            .temp => |t| std.fmt.allocPrint(allocator, "%t{d}", .{t + 1}),
            .spec_reg => |s| std.fmt.allocPrint(allocator, "%{s}", .{@tagName(s)}),
        };
    }
};

pub const Operands = struct {
    ops: []Operand,

    pub fn toJoinedString(self: Operands, allocator: std.mem.Allocator) ![]u8 {
        var list = std.array_list.Managed(u8).init(allocator);
        errdefer list.deinit();

        var first = true;
        for (self.ops) |op| {
            if (!first) try list.appendSlice(", ") else first = false;
            const s = try op.toString(allocator);
            defer allocator.free(s);
            try list.appendSlice(s);
        }
        return list.toOwnedSlice();
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

    pub fn deinit(self: *Line, alloc: std.mem.Allocator) void {
        alloc.free(self.uses.ops);
        alloc.free(self.defines.ops);
        alloc.free(self.live_out.ops);
    }
};

pub const Program = struct {
    register_count: i32,
    lines: []Line,
};

fn parse_temp_reg(s: []const u8) !Operand {
    if (s.len > 2 and s[0] == '%' and s[1] == 't') {
        const n = try std.fmt.parseInt(i32, s[2..], 10);
        return .{ .temp = n - 1 };
    }
    if (s.len > 1 and s[0] == '%') {
        if (spec_reg_map.get(s[1..])) |pr| {
            return .{ .spec_reg = pr };
        }
    }

    return error.UnkownRegister;
}

fn parse_temp_reg_list(alloc: std.mem.Allocator, ss: [][]const u8) !Operands {
    var count: usize = 0;
    for (ss) |_| {
        count += 1;
    }

    var out = try alloc.alloc(Operand, count);
    errdefer alloc.free(out);

    for (ss, 0..) |s, j| {
        out[j] = try parse_temp_reg(s);
    }
    return .{ .ops = out };
}

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
        std.debug.print("No //taget found", .{});
        return error.SyntaxError;
    };

    // advance after target
    var after: []const u8 = bytes[dpos + delim.len ..];

    // skip spaces/tabs
    after = std.mem.trimLeft(u8, after, " \t");

    // take remaining of line
    const nl = std.mem.indexOfScalar(u8, after, '\n') orelse return error.SyntaxError;
    const num_str = std.mem.trim(u8, after[0..nl], " \t");
    const reg_count = try std.fmt.parseInt(i32, num_str, 10);

    // move after json
    after = after[nl + 1 ..];

    const start = std.mem.indexOfScalar(u8, after, '[') orelse return error.SyntaxError;
    const json_src = after[start..];
    // std.debug.print("JSON slice (first 200):\n{s}\n", .{json_src[0..@min(json_src.len, 200)]});

    const parsed = try std.json.parseFromSlice([]RawLine, allocator, json_src, .{});
    defer parsed.deinit();

    var lines = try allocator.alloc(Line, parsed.value.len);
    var filled: usize = 0;
    errdefer {
        // free only what we filled so far
        var k: usize = 0;
        while (k < filled) : (k += 1) {
            lines[k].deinit(allocator);
        }
        allocator.free(lines);
    }
    for (parsed.value, 0..) |raw_line, i| {
        lines[i] = Line{
            .uses = try parse_temp_reg_list(allocator, raw_line.Uses),
            .defines = try parse_temp_reg_list(allocator, raw_line.Defines),
            .live_out = try parse_temp_reg_list(allocator, raw_line.Live_out),
            .move = raw_line.Move,
            .line_number = raw_line.Line,
        };
        filled = i + 1;
    }

    return .{ .lines = lines, .register_count = reg_count };
}
