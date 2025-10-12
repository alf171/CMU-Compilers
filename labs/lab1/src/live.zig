const std = @import("std");
const expect = std.testing.expect;
const parser = @import("parse.zig");

/// handle case where we are last line in addition to other to rest
pub fn getLiveOut(lines: std.array_list.Managed(parser.Line), index: usize, allocator: std.mem.Allocator) !parser.Operands {
    if (index + 1 >= lines.items.len) {
        return parser.Operands.init(allocator);
    }

    const line = lines.items[index + 1];
    return getLiveIn(line, allocator);
}

/// Live_in(line) = Uses(line) u (Live_out(line) - Define(line))
/// memory semantics, we are going to return new memory while keeping prev valid
fn getLiveIn(line: parser.Line, allocator: std.mem.Allocator) !parser.Operands {
    var result = std.array_list.Managed(parser.Operand).init(allocator);
    // copy items over
    try result.appendSlice(line.uses.ops.items);
    for (line.live_out.ops.items) |live_out| {
        // dont add duplicates + dont add if in define
        if (!parser.Operands.contains(line.uses, live_out) and !parser.Operands.contains(line.defines, live_out)) {
            try result.append(live_out);
        }
    }
    return parser.Operands{ .ops = result };
}

test "out of bounds returns empty" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const dummy_line = parser.Line{
        .uses = parser.Operands.init(allocator),
        .defines = parser.Operands.init(allocator),
        .live_out = parser.Operands.init(allocator),
        .move = false,
        .line_number = 0,
    };

    var lines = std.array_list.Managed(parser.Line).init(allocator);
    try lines.append(dummy_line);

    const result = try getLiveOut(lines, 0, allocator);
    defer result.free();

    try std.testing.expectEqual(@as(usize, 0), result.ops.items.len);

    lines.items[0].deinit();
    lines.deinit();
    try std.testing.expect(gpa.deinit() == .ok);
}

test "simple example" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const line_1 = parser.Line{
        .uses = parser.Operands.init(allocator),
        .defines = parser.Operands.init(allocator),
        .live_out = parser.Operands.init(allocator),
        .move = false,
        .line_number = 2,
    };

    var uses_2 = parser.Operands.init(allocator);
    try uses_2.ops.append(parser.Operand{ .temp = 0 });
    var defines_2 = parser.Operands.init(allocator);
    try defines_2.ops.append(parser.Operand{ .temp = 1 });
    var live_out_2 = parser.Operands.init(allocator);
    const temps = [_]parser.Operand{
        .{ .temp = 0 },
        .{ .temp = 1 },
        .{ .temp = 2 },
    };
    try live_out_2.ops.appendSlice(temps[0..]);
    const line_2 = parser.Line{
        .uses = uses_2,
        .defines = defines_2,
        .live_out = live_out_2,
        .move = false,
        .line_number = 1,
    };

    var lines = std.array_list.Managed(parser.Line).init(allocator);
    try lines.append(line_1);
    try lines.append(line_2);
    const result = try getLiveOut(lines, 0, allocator);

    try std.testing.expectEqual(@as(usize, 2), result.ops.items.len);
    try std.testing.expect(result.contains(parser.Operand{ .temp = 0 }));
    try std.testing.expect(result.contains(parser.Operand{ .temp = 2 }));

    lines.items[0].deinit();
    lines.items[1].deinit();
    lines.deinit();
    result.free();
    try std.testing.expect(gpa.deinit() == .ok);
}
