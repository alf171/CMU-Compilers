const std = @import("std");

const c = @import("frontend").python.c;
const walkAst = @import("frontend").walk.walkAst;
const middle = @import("middle");
const loop = middle.loop;
const lower = middle.lower;
const live = middle.live;
const igraph = middle.igraph;
const color = middle.color;
const phi = middle.phi;
const copy = middle.copy;
const dead = middle.dead;
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
    var should_dump_ir = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--run")) should_run = true;
        if (std.mem.eql(u8, arg, "--optim")) should_optim = true;
        if (std.mem.eql(u8, arg, "--dump-ir")) should_dump_ir = true;
    }

    const code = try std.Io.Dir.cwd().readFileAlloc(io, input_file, alloc, .limited(1 << 20));
    const code_z = try alloc.dupeSentinel(u8, code, 0);

    std.debug.print("{s}running program:{s}", .{ underline_code, reset_code });
    if (should_optim) std.debug.print(" (OPTIM={})", .{should_optim});
    std.debug.print("\n\n{s}", .{code});

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code_z.ptr);
    std.debug.assert(tree != null);

    var ir_program = try walkAst(tree, alloc);
    defer ir_program.deinit(alloc);

    // dump ir after optim pass
    if (should_dump_ir) {
        std.debug.print("\n{s}pre phi elimination:{s}\n", .{ underline_code, reset_code });
        try ir_program.print();
    }

    // run optimization passses
    if (should_optim) {
        try copy.run(&ir_program, alloc);
        // TODO: turn back on once matmul works
        // try dead.run(&ir_program, alloc);
    }

    try phi.eliminatePhi(&ir_program, alloc);

    // dump ir after optim pass
    if (should_dump_ir) {
        std.debug.print("\n{s}post phi elimination:{s}\n", .{ underline_code, reset_code });
        try ir_program.print();
    }

    var alloc_program = try lower.lowerAlloc(ir_program, alloc);

    defer alloc_program.deinit();

    try live.calculateLiveOut(&alloc_program, alloc);

    var graph = try igraph.createIgraph(alloc_program.lines, alloc);
    defer graph.deinit();

    const file = try std.Io.Dir.createFileAbsolute(io, output_file, .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);

    var colored = try loop.run(&ir_program, &alloc_program, should_optim, alloc, null);
    defer colored.deinit();

    // dump colored graph
    if (should_dump_ir) {
        std.debug.print("\n{s}post register alloc:{s}\n", .{ underline_code, reset_code });
        try ir_program.print();
    }

    const asm_text = try emit(&ir_program, &colored, alloc);
    defer alloc.free(asm_text);

    // TODO: break metrics up into their own module
    if (should_dump_ir) {
        var lines = std.mem.splitScalar(u8, asm_text, '\n');
        var line_count: usize = 0;
        var mov_count: usize = 0;
        var memory_load_count: usize = 0;
        var memory_store_count: usize = 0;
        var branches: usize = 0;
        var calls: usize = 0;
        while (lines.next()) |line| {
            const trim = std.mem.trim(u8, line, "\t");

            if (trim.len == 0) continue;

            if (trim[0] == '.' or trim[0] == '_') continue;

            line_count += 1;
            if (std.mem.startsWith(u8, trim, "mov ")) mov_count += 1;
            if (std.mem.startsWith(u8, trim, "ldr ")) memory_load_count += 1;
            if (std.mem.startsWith(u8, trim, "str ")) memory_store_count += 1;
            if (std.mem.startsWith(u8, trim, "ret ") or std.mem.startsWith(u8, trim, "b ")) branches += 1;
            if (std.mem.startsWith(u8, trim, "bl ")) calls += 1;
        }
        std.debug.print("\n{s}performance report:{s}\n", .{ underline_code, reset_code });
        std.debug.print("number of asm lines: {d}\n", .{line_count});
        std.debug.print("mov count: {d}\n", .{mov_count});
        std.debug.print("memory load count: {d}\n", .{memory_load_count});
        std.debug.print("memory store count: {d}\n", .{memory_store_count});
        std.debug.print("branch count: {d}\n", .{branches});
        std.debug.print("call count: {d}\n", .{calls});
    }

    try file_writer.interface.writeAll(asm_text);
    try file_writer.interface.flush();

    if (should_run) {
        const dir = std.fs.path.dirname(output_file) orelse ".";
        const stem = std.fs.path.stem(output_file);
        const obj_name = try std.fmt.allocPrint(alloc, "{s}.o", .{stem});
        defer alloc.free(obj_name);
        const obj_file = try std.fs.path.join(alloc, &.{ dir, obj_name });
        defer alloc.free(obj_file);

        // clang -c src/out.s -o /tmp/out.o
        const clang_object_result = try runCommand(alloc, io, &.{ "clang", "-c", output_file, "-o", obj_file });
        defer alloc.free(clang_object_result.stdout);
        defer alloc.free(clang_object_result.stderr);
        // clang -c src/malloc.c -o /tmp/malloc.o
        const clang_malloc_result = try runCommand(alloc, io, &.{ "clang", "-c", "src/malloc.c", "-o", "/tmp/malloc.o" });
        defer alloc.free(clang_malloc_result.stdout);
        defer alloc.free(clang_malloc_result.stderr);
        // create /tmp/integration_out
        const clang_final_result = try runCommand(alloc, io, &.{ "clang", obj_file, "/tmp/malloc.o", "-o", "/tmp/integration_out" });
        defer alloc.free(clang_final_result.stdout);
        defer alloc.free(clang_final_result.stderr);
        // run!
        const run_result = try runCommand(alloc, io, &.{"/tmp/integration_out"});
        defer alloc.free(run_result.stdout);
        defer alloc.free(run_result.stderr);

        std.debug.print("\n{s}actual output:{s}\n{s}", .{ underline_code, reset_code, run_result.stdout });
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
