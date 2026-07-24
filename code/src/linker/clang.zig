const std = @import("std");
const runCommand = @import("shared.zig").runCommand;
const LinkerRequest = @import("shared.zig").LinkerRequest;

pub fn assemble(request: LinkerRequest, io: std.Io, alloc: std.mem.Allocator) !void {
    // clang -c /tmp/host.s -o /tmp/host.o
    const clang_object_result = try runCommand(
        alloc,
        io,
        &.{ "clang", "-c", request.input_file, "-o", request.output_file },
    );
    defer alloc.free(clang_object_result.stdout);
    defer alloc.free(clang_object_result.stderr);
    // clang -c src/malloc.c -o /tmp/malloc.o
    const clang_malloc_result = try runCommand(alloc, io, &.{ "clang", "-c", "src/malloc.c", "-o", "/tmp/malloc.o" });
    defer alloc.free(clang_malloc_result.stdout);
    defer alloc.free(clang_malloc_result.stderr);

    //include hsa
    if (request.target.device != .host) {
        const hsa_runtime_path = request.hsa_runtime_path orelse return error.CantFindHsaPath;
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
}
