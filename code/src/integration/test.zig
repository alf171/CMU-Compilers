const std = @import("std");

const c = @import("frontend").python.c;
const walkAstWithRuntime = @import("frontend").run.walkAstWithRuntime;
const range = @import("frontend").range;
const write = @import("frontend").write;
const middle = @import("middle");
const loop = middle.loop;
const lower = middle.lower;
const live = middle.live;
const igraph = middle.igraph;
const color = middle.color;
const phi = middle.phi;
const parallel_copies = middle.parallel_copies;
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
    var should_dump_stats = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--run")) should_run = true;
        if (std.mem.eql(u8, arg, "--optim")) should_optim = true;
        if (std.mem.eql(u8, arg, "--dump-ir")) should_dump_ir = true;
        if (std.mem.eql(u8, arg, "--dump-stats")) should_dump_stats = true;
    }

    // walk user program
    var ir_program = try walkAstWithRuntime(input_file, should_optim, io, alloc);
    defer ir_program.deinit(alloc);

    // dump ir after optim pass
    if (should_dump_ir) {
        std.debug.print("\n{s}pre phi elimination:{s}\n", .{ underline_code, reset_code });
        try ir_program.print();
    }

    // run optimization passses
    if (should_optim) {
        try copy.run(&ir_program, alloc);
    }

    // range elimination?
    try range.rewrite(&ir_program, alloc);
    try write.rewrite(&ir_program, alloc);
    // phi cleanup
    try phi.eliminatePhi(&ir_program, alloc);
    try parallel_copies.lower(&ir_program, alloc);

    // dump ir after optim pass
    if (should_dump_ir) {
        std.debug.print("\n{s}post phi elimination:{s}\n", .{ underline_code, reset_code });
        try ir_program.print();
    }

    var alloc_program = try lower.lowerAlloc(ir_program, alloc);
    try live.calculateLiveOut(&alloc_program, alloc);

    // run optimzation passes
    if (should_optim) {
        try dead.run(&ir_program, &alloc_program, alloc);
        alloc_program.deinit(alloc);
        alloc_program = try lower.lowerAlloc(ir_program, alloc);
        try live.calculateLiveOut(&alloc_program, alloc);
    }

    defer alloc_program.deinit(alloc);

    var graph = try igraph.createIgraph(alloc_program.lines, alloc);
    defer graph.deinit();

    const file = try std.Io.Dir.createFileAbsolute(io, output_file, .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);

    const result = try loop.run(&ir_program, &alloc_program, should_optim, alloc, null);
    var colored = result.graph;
    defer colored.deinit();

    // dump colored graph
    if (should_dump_ir) {
        std.debug.print("\n{s}post register alloc:{s}\n", .{ underline_code, reset_code });
        try ir_program.print();
    }

    const asm_text = try emit(&ir_program, &colored, alloc);
    defer alloc.free(asm_text);

    // TODO: break metrics up into their own module
    if (should_dump_stats) {
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
        std.debug.print("spill count: {d}\n", .{result.spill_rounds});
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
