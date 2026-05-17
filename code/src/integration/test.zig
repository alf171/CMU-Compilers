const std = @import("std");

const c = @import("frontend").python.c;
const walkAst = @import("frontend").walk.walkAst;
const lower = @import("middle").lower;
const live = @import("middle").live;
const igraph = @import("middle").igraph;
const color = @import("middle").color;
const phi = @import("middle").phi;
const copy = @import("middle").copy;
const dead = @import("middle").dead;
const emit = @import("backend").emit;

const underline_code = "\x1b[4m";
const reset_code = "\x1b[0m";

pub fn main(init: std.process.Init) !void {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const arena = init.arena;
    const args = try init.minimal.args.toSlice(arena.allocator());
    const io = init.io;
    const alloc = arena.allocator();

    if (args.len < 3) {
        std.debug.print("usage: {s} <input file> <output asm> [--run]\n", .{args[0]});
        return;
    }

    const input_file = args[1];
    const output_file = args[2];
    var should_run = false;
    var should_optim = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--run")) should_run = true;
        if (std.mem.eql(u8, arg, "--optim")) should_optim = true;
    }

    const code = try std.Io.Dir.cwd().readFileAlloc(io, input_file, alloc, .limited(1 << 20));
    const code_z = try alloc.dupeSentinel(u8, code, 0);

    std.debug.print("{s}running program:{s}", .{ underline_code, reset_code });
    if (should_optim) std.debug.print(" (OPTIM={})", .{should_optim});
    std.debug.print("\n{s}", .{code});

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code_z.ptr);
    std.debug.assert(tree != null);

    var ir_program = try walkAst(tree, alloc);
    defer ir_program.deinit();

    // run optimization passses
    if (should_optim) {
        try copy.run(&ir_program, alloc);
        try dead.run(&ir_program, alloc);
    }

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

    if (should_run) {
        const clangd_result = try runCommand(alloc, io, &.{ "clang", output_file, "-o", "/tmp/integration_out" });
        defer alloc.free(clangd_result.stdout);
        defer alloc.free(clangd_result.stderr);
        const run_result = try runCommand(alloc, io, &.{"/tmp/integration_out"});
        defer alloc.free(run_result.stdout);
        defer alloc.free(run_result.stderr);
        std.debug.print("{s}actual output:{s}\n{s}", .{ underline_code, reset_code, run_result.stdout });
    }
}

fn runCommand(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("command failed : {s}\nstderr:\n{s}\n", .{ argv[0], result.stderr });
                alloc.free(result.stdout);
                alloc.free(result.stderr);
                return error.CommandFailed;
            }
        },
        else => {
            alloc.free(result.stdout);
            alloc.free(result.stderr);
            return error.CommandFailed;
        },
    }
    return result;
}
