const std = @import("std");

const c = @import("frontend").python.c;
const walkAst = @import("frontend").walk.walkAst;
const lower = @import("middle").lower;
const live = @import("middle").live;
const igraph = @import("middle").igraph;
const color = @import("middle").color;
const phi = @import("middle").phi;
const emit = @import("backend").emit;

pub fn main(init: std.process.Init) !void {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const arena = init.arena;
    const args = try init.minimal.args.toSlice(arena.allocator());
    const io = init.io;
    const alloc = arena.allocator();

    if (args.len == 4) {
        std.debug.print("usage: {s} <input file> <output file>\n", .{args[0]});
        return;
    }

    const input_file = args[1];
    const output_file = args[2];

    const code = try std.Io.Dir.cwd().readFileAlloc(io, input_file, alloc, .limited(1 << 20));
    const code_z = try alloc.dupeSentinel(u8, code, 0);

    std.debug.print("running program:\n{s}", .{code});

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code_z.ptr);
    std.debug.assert(tree != null);

    var ir_program = try walkAst(tree, alloc);
    defer ir_program.deinit();

    try phi.eliminatePhi(&ir_program, alloc);

    var alloc_program = try lower.lowerAlloc(ir_program, alloc);
    defer alloc_program.deinit();

    try live.calculateLiveOut(alloc_program);

    var graph = try igraph.createIgraph(alloc_program.lines, alloc);
    defer graph.deinit();

    var attempt = try color.colorGraph(&graph, alloc_program.register_count, alloc);

    const file = try std.Io.Dir.createFileAbsolute(io, output_file, .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);

    switch (attempt) {
        .graph => |*colored| {
            defer colored.deinit();

            const asm_text = try emit(&ir_program, colored, alloc);
            defer alloc.free(asm_text);

            try file_writer.interface.writeAll(asm_text);
            try file_writer.interface.flush();
        },
        .spill_register => {
            return error.UnexpectedSpill;
        },
    }
}
