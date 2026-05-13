const std = @import("std");
const common = @import("common");
const SpecialRegs = common.ir.SpecialRegs;
const spec_reg_map = common.ir.spec_reg_map;

const Program = common.alloc.AllocProgram;
const Operands = common.alloc.Operands;
const Operand = common.alloc.Operand;
const Line = common.alloc.AllocLine;

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const RawLine = struct {
    Uses: [][]const u8,
    Defines: [][]const u8,
    Live_out: [][]const u8,
    Move: bool,
    Line: usize,
};

/// keep track of the largest temp currently used to easy implement spilling
// pub const Program = struct {
//     /// how many registers the program needs to utilize
//     register_count: u8,
//     /// the raw lines being passed into the program
//     lines: std.array_list.Managed(Line),
//     /// keep track of largest temp used in program
//     max_temp_reg: u8,
//     /// keep track of memory uses
//     mem_pointer: u8,
//
//     pub fn print(program: @This(), stdout: *Writer) !void {
//         try stdout.print("register count: {d}\n", .{program.register_count});
//
//         for (program.lines.items) |line| {
//             try stdout.print("[{d}] ", .{line.line_number});
//             if (line.defines.ops.items.len == 0) {
//                 try stdout.print("_ <- ", .{});
//             } else {
//                 // assume we only define a single temp
//                 try line.defines.ops.items[0].print(stdout);
//                 try stdout.print(" <- ", .{});
//             }
//             if (line.uses.ops.items.len > 0) {
//                 if (!line.move) {
//                     try stdout.print("op(", .{});
//                 }
//                 for (line.uses.ops.items, 0..) |use, i| {
//                     try use.print(stdout);
//                     // if not last element
//                     if (i + 1 != line.uses.ops.items.len) {
//                         try stdout.print(", ", .{});
//                     }
//                 }
//                 if (!line.move) {
//                     try stdout.print(")", .{});
//                 }
//             } else {
//                 try stdout.print("_", .{});
//             }
//
//             // print live_out info
//             try stdout.print(" [", .{});
//             for (line.live_out.ops.items, 0..) |live_out, i| {
//                 if (i != 0) {
//                     try stdout.print("", .{});
//                 }
//                 try live_out.print(stdout);
//                 if (i + 1 != line.live_out.ops.items.len) {
//                     try stdout.print(", ", .{});
//                 }
//             }
//             try stdout.print("]", .{});
//
//             try stdout.print("\n", .{});
//         }
//         try stdout.flush();
//     }
//
//     pub fn deinit(program: Program) void {
//         for (program.lines.items) |*line| {
//             line.deinit();
//         }
//         program.lines.deinit();
//     }
// };

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

fn parse_temp_reg_list(alloctor: Allocator, ss: [][]const u8) !Operands {
    var count: usize = 0;
    for (ss) |_| {
        count += 1;
    }

    var res = Operands.init(alloctor);
    errdefer res.free();

    for (ss) |s| {
        const out_val = try parse_temp_reg(s);
        try res.ops.put(out_val, {});
    }
    return res;
}

/// Go from file_name -> data struct to test our compiler
/// within this middle step of the compiler
pub fn parse(filename: []const u8, io: std.Io, allocator: Allocator) !Program {
    std.debug.print("Got filename: {s}\n", .{filename});
    const file = try std.Io.Dir.cwd().openFile(io, filename, .{
        .mode = .read_only,
    });
    defer file.close(io);

    // cap read to 1mb; adjust as needed
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1 << 20));
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
    after = std.mem.trim(u8, after, " \t");

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
            .instruction_index = raw_line.Line,
        });
        filled = i + 1;
        if (lines.items[i].defines.ops.count() > 0) {
            switch (try lines.items[i].defines.single()) {
                .temp => |v| {
                    max_temp_reg = @max(v, max_temp_reg);
                },
                else => {},
            }
        }
    }

    var blocks = std.array_list.Managed(common.alloc.AllocBlock).init(allocator);
    const successors = std.array_list.Managed(u32).init(allocator);
    try blocks.append(.{
        .id = 0,
        .start = 0,
        .end = 0,
        .successors = successors,
    });
    return Program{
        .lines = lines,
        .blocks = blocks,
        .register_count = reg_count,
    };
}
