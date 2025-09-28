const std = @import("std");
const parser = @import("parse.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    // Grab command-line arguments
    const args = try std.process.argsAlloc(A);
    defer std.process.argsFree(A, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} <filename>\n", .{args[0]});
        return;
    }

    const filename = args[1];
    const program: parser.Program = try parser.parse(filename, A);
    defer {
        for (program.lines) |*l| {
            l.deinit(A);
        }
        A.free(program.lines);
    }

    std.debug.print("register count: {d}\n", .{program.register_count});
    for (program.lines, 0..) |line, i| {
        const uses = try line.uses.toJoinedString(A);
        defer A.free(uses);

        const defs = try line.defines.toJoinedString(A);
        defer A.free(defs);

        const live = try line.live_out.toJoinedString(A);
        defer A.free(live);

        std.debug.print(
            "line[{d}] = (uses: {s}, defines: {s}, live_out: {s}, move: {}, line num: {d})\n",
            .{ i, uses, defs, live, line.move, line.line_number },
        );
    }
}
