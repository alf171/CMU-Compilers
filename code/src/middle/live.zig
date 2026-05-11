const std = @import("std");
const expect = std.testing.expect;
const parser = @import("parse.zig");

// const Line = parser.Line;
const Line = @import("common").alloc.AllocLine;
const Operands = @import("common").alloc.Operands;
const Operand = @import("common").alloc.Operand;

/// handle case where we are last line in addition to other to rest
pub fn calculateLiveOut(lines: std.array_list.Managed(Line)) !void {
    var index: usize = lines.items.len - 1;
    while (index > 0) : (index -= 1) {
        const next_line = lines.items[index];
        try getLiveIn(&lines.items[index - 1].live_out, next_line);
    }
}

/// Live_in(line) = Uses(line) u (Live_out(line) - Define(line))
/// memory semantics, we are going to return new memory while keeping prev valid
fn getLiveIn(result: *Operands, line: Line) !void {
    try result.ops.appendSlice(line.uses.ops.items);
    for (line.live_out.ops.items) |live_out| {
        // dont add duplicates + dont add if in define
        if (!Operands.contains(line.uses, live_out) and !Operands.contains(line.defines, live_out)) {
            try result.ops.append(live_out);
        }
    }
}

// test "out of bounds returns empty" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     const dummy_line = Line{
//         .uses = Operands.init(allocator),
//         .defines = Operands.init(allocator),
//         .live_out = Operands.init(allocator),
//         .move = false,
//         .line_number = 0,
//     };
//
//     var lines = std.array_list.Managed(Line).init(allocator);
//     try lines.append(dummy_line);
//
//     const result = try getLiveOut(lines, 0, allocator);
//     defer result.free();
//
//     try std.testing.expectEqual(@as(usize, 0), result.ops.items.len);
//
//     lines.items[0].deinit();
//     lines.deinit();
//     try std.testing.expect(gpa.deinit() == .ok);
// }
//
// test "simple example" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     const line_1 = Line{
//         .uses = Operands.init(allocator),
//         .defines = Operands.init(allocator),
//         .live_out = Operands.init(allocator),
//         .move = false,
//         .line_number = 2,
//     };
//
//     var uses_2 = Operands.init(allocator);
//     try uses_2.ops.append(Operand{ .temp = 0 });
//     var defines_2 = Operands.init(allocator);
//     try defines_2.ops.append(Operand{ .temp = 1 });
//     var live_out_2 = Operands.init(allocator);
//     const temps = [_]Operand{
//         .{ .temp = 0 },
//         .{ .temp = 1 },
//         .{ .temp = 2 },
//     };
//     try live_out_2.ops.appendSlice(temps[0..]);
//     const line_2 = Line{
//         .uses = uses_2,
//         .defines = defines_2,
//         .live_out = live_out_2,
//         .move = false,
//         .line_number = 1,
//     };
//
//     var lines = std.array_list.Managed(Line).init(allocator);
//     try lines.append(line_1);
//     try lines.append(line_2);
//     const result = try getLiveOut(lines, 0, allocator);
//
//     try std.testing.expectEqual(@as(usize, 2), result.ops.items.len);
//     try std.testing.expect(result.contains(Operand{ .temp = 0 }));
//     try std.testing.expect(result.contains(Operand{ .temp = 2 }));
//
//     lines.items[0].deinit();
//     lines.items[1].deinit();
//     lines.deinit();
//     result.free();
//     try std.testing.expect(gpa.deinit() == .ok);
// }
