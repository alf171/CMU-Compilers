const std = @import("std");

const c = @import("frontend").python.c;
const walkAst = @import("frontend").walk.walkAst;
const lower = @import("middle").lower;
const live = @import("middle").live;
const igraph = @import("middle").igraph;
const color = @import("middle").color;
const emit = @import("backend").emit;

test "python source lowers to allocation lines" {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const code: [*:0]const u8 =
        \\a = 5
        \\b = 10
        \\print(a + b)
    ;

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code);
    std.debug.assert(tree != null);

    var ir_program = try walkAst(tree, alloc);
    defer ir_program.deinit();

    var alloc_program = try lower.lowerAlloc(ir_program, alloc);
    defer alloc_program.deinit();

    try std.testing.expectEqual(@as(usize, 8), alloc_program.lines.items.len);

    try live.calculateLiveOut(alloc_program.lines);

    var graph = try igraph.createIgraph(alloc_program.lines, alloc);
    defer graph.deinit();
    try std.testing.expect(graph.nodes.count() > 0);

    var attempt = try color.colorGraph(&graph, alloc_program.register_count, alloc);

    const file = try std.Io.Dir.createFileAbsolute(io, "/tmp/out.s", .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);

    switch (attempt) {
        .graph => |*colored| {
            defer colored.deinit();
            try std.testing.expect(colored.nodes.count() > 0);

            const asm_text = try emit(&ir_program, colored, alloc);
            defer alloc.free(asm_text);

            try std.testing.expect(std.mem.indexOf(u8, asm_text, "_main") != null);
            try std.testing.expect(std.mem.indexOf(u8, asm_text, "bl _printf") != null);

            std.debug.print("{s}\n", .{asm_text});

            try file_writer.interface.writeAll(asm_text);
            try file_writer.interface.flush();
        },
        .spill_register => {
            return error.UnexpectedSpill;
        },
    }
}
