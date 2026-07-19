const std = @import("std");

const c = @import("frontend").python.c;
const walkAstWithRuntime = @import("frontend").run.walkAstWithRuntime;
const tuple = @import("frontend").tuple;
const lazy = @import("frontend").lazy;
const list = @import("frontend").list;
const print = @import("frontend").print;
const func = @import("frontend").func;
const middle = @import("middle");
const backend = @import("backend");
const Target = backend.Target;
const CompilationArifacts = backend.CompilationArifacts;
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
    var should_run = false;
    var should_optim = false;
    var should_dump_ir = false;
    var should_dump_stats = false;
    var use_escape_codes = true;
    // default target
    var target: Target = .{
        .host = .X86,
        .device = .gfx1103,
    };
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--run")) should_run = true;
        if (std.mem.eql(u8, arg, "--optim")) should_optim = true;
        if (std.mem.eql(u8, arg, "--dump-ir")) should_dump_ir = true;
        if (std.mem.eql(u8, arg, "--dump-stats")) should_dump_stats = true;
        if (std.mem.eql(u8, arg, "--omit-escape-codes")) use_escape_codes = false;
        // allow caller to decide their platform
        if (std.mem.eql(u8, arg, "--host=arm")) target.host = .ARM;
        if (std.mem.eql(u8, arg, "--host=x86")) target.host = .X86;
        if (std.mem.eql(u8, arg, "--device=host")) target.device = .host;
        if (std.mem.eql(u8, arg, "--device=gfx1103")) target.device = .gfx1103;
    }

    // walk user program
    var ir_program = try walkAstWithRuntime(input_file, should_optim, use_escape_codes, io, alloc);
    defer ir_program.deinit(alloc);

    // rewrite layer
    try lazy.rewrite(&ir_program, alloc);
    try tuple.rewrite(&ir_program, alloc);
    try list.rewrite(&ir_program, alloc);
    try print.rewrite(&ir_program, alloc);
    try func.rewrite(&ir_program, alloc);

    // phi cleanup
    try phi.eliminatePhi(&ir_program, alloc);

    const host_platform = try target.host.getPlatform();
    try precolor.apply(&ir_program, host_platform.abi, alloc);
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

    var alloc_program = try reg_alloc.build(ir_program, @intCast(host_platform.abi.gp_allocatable_regs.len), alloc);
    try live.calculateLiveOut(&alloc_program, alloc);

    // run optimzation passes
    if (should_optim) {
        try dead.run(&ir_program, &alloc_program, alloc);
        alloc_program.deinit(alloc);
        alloc_program = try reg_alloc.build(ir_program, @intCast(host_platform.abi.gp_allocatable_regs.len), alloc);
        try live.calculateLiveOut(&alloc_program, alloc);
    }

    defer alloc_program.deinit(alloc);

    var graph = try igraph.createIgraph(alloc_program.lines, host_platform.abi.gp_call_clobber_mask, alloc);
    defer graph.deinit();

    const result = try loop.run(
        &ir_program,
        &graph,
        &alloc_program,
        should_optim,
        host_platform.abi.gp_call_clobber_mask,
        alloc,
        null,
    );
    var host_colors = result.graph;
    defer host_colors.deinit();

    // dump colored graph
    if (should_dump_ir) {
        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("post register allocation:", .{});
        if (use_escape_codes) std.debug.print("{s}", .{reset_code});
        std.debug.print("\n", .{});
        try ir_program.print();
    }

    var artifacts = try (backend.CompileRequest{
        .program = &ir_program,
        .host_colors = &host_colors,
        .target = target,
    }).compile(alloc);
    defer artifacts.deinit(alloc);

    if (should_dump_stats) {
        const stats = metrics.get(artifacts.host_asm, result.spill_rounds, target);
        stats.user.print(use_escape_codes);
        stats.runtime.print(use_escape_codes);
    }

    const output_file = "/tmp/host.s";
    try writeArtifact(output_file, artifacts.host_asm, io);
    if (artifacts.device_asm) |device_asm|
        try writeArtifact("/tmp/device.s", device_asm, io);

    if (should_run) {
        if (artifacts.device_asm != null) {
            const device_asm_result = try runCommand(alloc, io, &.{
                "clang",
                "-target",
                "amdgcn-amd-amdhsa",
                "-mcpu=gfx1103",
                "-c",
                "/tmp/device.s",
                "-o",
                "/tmp/device.o",
            });
            defer alloc.free(device_asm_result.stdout);
            defer alloc.free(device_asm_result.stderr);

            const device_link_result = try runCommand(alloc, io, &.{
                "ld.lld",
                "-shared",
                "/tmp/device.o",
                "-o",
                "/tmp/device.co",
            });
            defer alloc.free(device_link_result.stdout);
            defer alloc.free(device_link_result.stderr);
        }
        const dir = std.fs.path.dirname(output_file) orelse ".";
        const stem = std.fs.path.stem(output_file);
        const obj_name = try std.fmt.allocPrint(alloc, "{s}.o", .{stem});
        defer alloc.free(obj_name);
        const obj_file = try std.fs.path.join(alloc, &.{ dir, obj_name });
        defer alloc.free(obj_file);

        // clang -c src/host.s -o /tmp/host.o
        const clang_object_result = try runCommand(alloc, io, &.{ "clang", "-c", output_file, "-o", obj_file });
        defer alloc.free(clang_object_result.stdout);
        defer alloc.free(clang_object_result.stderr);
        // clang -c src/malloc.c -o /tmp/malloc.o
        const clang_malloc_result = try runCommand(alloc, io, &.{ "clang", "-c", "src/malloc.c", "-o", "/tmp/malloc.o" });
        defer alloc.free(clang_malloc_result.stdout);
        defer alloc.free(clang_malloc_result.stderr);

        //include hsa
        if (target.device != .host) {
            const hsa_runtime_path = init.environ_map.get("HSA_RUNTIME_PATH") orelse return error.CantFindHsaPath;
            const hsa_include = try std.fs.path.join(alloc, &.{ hsa_runtime_path, "include" });
            defer alloc.free(hsa_include);
            // clang -I ($HSA_RUNTIME_PATH)/include -c src/gpu.c -o /tmp/gpu.o
            const gpu_result = try runCommand(alloc, io, &.{
                "clang",
                "-I",
                hsa_include,
                "-c",
                "src/gpu.c",
                "-o",
                "/tmp/gpu.o",
            });
            defer alloc.free(gpu_result.stdout);
            defer alloc.free(gpu_result.stderr);
        }

        // create /tmp/integration_out
        const clang_final_result = if (target.device == .host)
            try runCommand(alloc, io, &.{
                "clang",
                obj_file,
                "/tmp/malloc.o",
                "-o",
                "/tmp/integration_out",
            })
        else
            try runCommand(alloc, io, &.{
                "clang",
                obj_file,
                "/tmp/malloc.o",
                "/tmp/gpu.o",
                "-lhsa-runtime64",
                "-o",
                "/tmp/integration_out",
            });
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

fn writeArtifact(output_file: []const u8, contents: []const u8, io: std.Io) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, output_file, .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);
    try file_writer.interface.writeAll(contents);
    try file_writer.interface.flush();
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
