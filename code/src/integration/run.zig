const std = @import("std");

const c = @import("frontend").python.c;
const walkAstWithRuntime = @import("frontend").run.walkAstWithRuntime;
const tuple = @import("frontend").tuple;
const lazy = @import("frontend").lazy;
const list = @import("frontend").list;
const print = @import("frontend").print;
const middle = @import("middle");
const backend = @import("backend");
const getPlatform = backend.getPlatform;
const Target = backend.Target;
const metrics = @import("metrics.zig");
const loop = middle.loop;
const reg_alloc = middle.reg_alloc;
const live = middle.live;
const igraph = middle.igraph;
const color = middle.color;
const precolor = middle.precolor;
const phi = middle.phi;
const parallel_copies = middle.parallel_copies;
const copy = middle.copy;
const dead = middle.dead;

const underline_code = "\x1b[4m";
const reset_code = "\x1b[0m";

pub fn main(init: std.process.Init) !void {
    c.Py_Initialize();
    defer _ = c.Py_FinalizeEx();

    const arena = init.arena;
    const args = try init.minimal.args.toSlice(arena.allocator());
    const io = init.io;

    // var alloc = arena.allocator();
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer {
        const status = debug_alloc.deinit();
        if (status == .leak) {
            std.debug.print("leaks detected\n", .{});
        }
    }
    const alloc = debug_alloc.allocator();

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
    var use_escape_codes = true;
    var target: Target = .ARM;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--run")) should_run = true;
        if (std.mem.eql(u8, arg, "--optim")) should_optim = true;
        if (std.mem.eql(u8, arg, "--dump-ir")) should_dump_ir = true;
        if (std.mem.eql(u8, arg, "--dump-stats")) should_dump_stats = true;
        if (std.mem.eql(u8, arg, "--omit-escape-codes")) use_escape_codes = false;
        // allow caller to decide their platform
        if (std.mem.eql(u8, arg, "--platform=arm")) target = .ARM;
        if (std.mem.eql(u8, arg, "--platform=x86")) target = .X86;
    }

    // walk user program
    var ir_program = try walkAstWithRuntime(input_file, should_optim, use_escape_codes, io, alloc);
    defer ir_program.deinit(alloc);

    // rewrite layer
    try lazy.rewrite(&ir_program, alloc);
    try tuple.rewrite(&ir_program, alloc);
    try list.rewrite(&ir_program, alloc);
    try print.rewrite(&ir_program, alloc);
    // phi cleanup
    try phi.eliminatePhi(&ir_program, alloc);

    const platform = try getPlatform(target);
    try precolor.apply(&ir_program, platform.abi, alloc);
    try parallel_copies.lower(&ir_program, alloc);

    // run optimization passses
    if (should_optim) {
        try copy.run(&ir_program, alloc);
    }

    // dump ir after optim pass
    if (should_dump_ir) {
        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("post phi elimination:", .{});
        if (use_escape_codes) std.debug.print("{s}", .{reset_code});
        std.debug.print("\n", .{});
        try ir_program.print();
    }

    var alloc_program = try reg_alloc.build(ir_program, @intCast(platform.abi.gp_allocatable_regs.len), alloc);
    try live.calculateLiveOut(&alloc_program, alloc);

    // run optimzation passes
    if (should_optim) {
        try dead.run(&ir_program, &alloc_program, alloc);
        alloc_program.deinit(alloc);
        alloc_program = try reg_alloc.build(ir_program, @intCast(platform.abi.gp_allocatable_regs.len), alloc);
        try live.calculateLiveOut(&alloc_program, alloc);
    }

    defer alloc_program.deinit(alloc);

    var graph = try igraph.createIgraph(alloc_program.lines, platform.abi.gp_call_clobber_mask, alloc);
    defer graph.deinit();

    const file = try std.Io.Dir.createFileAbsolute(io, output_file, .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);

    const result = try loop.run(&ir_program, &graph, &alloc_program, should_optim, platform.abi.gp_call_clobber_mask, alloc, null);
    var colored = result.graph;
    defer colored.deinit();

    // dump colored graph
    if (should_dump_ir) {
        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("post register allocation:", .{});
        if (use_escape_codes) std.debug.print("{s}", .{reset_code});
        std.debug.print("\n", .{});
        try ir_program.print();
    }

    const asm_text = try platform.emit(&ir_program, &colored, platform.abi, alloc);
    defer alloc.free(asm_text);

    if (should_dump_stats) {
        const stats = metrics.get(asm_text, result.spill_rounds, target);
        stats.user.print(use_escape_codes);
        stats.runtime.print(use_escape_codes);
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

        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("actual output:", .{});
        if (use_escape_codes) std.debug.print("{s}", .{reset_code});
        std.debug.print("\n", .{});
        std.debug.print("{s}", .{run_result.stdout});
    }
}

pub fn runCommand(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "command failed: {s}\nterm: {any}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ argv[0], result.term, result.stdout, result.stderr },
        );

        alloc.free(result.stdout);
        alloc.free(result.stderr);
        return error.CommandFailed;
    }
    return result;
}
