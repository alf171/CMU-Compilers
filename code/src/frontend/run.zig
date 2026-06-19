const std = @import("std");
const c = @import("python.zig").c;
const PyObject = c.PyObject;
const Program = @import("common").program.Program;
const IrBuilder = @import("builder.zig").IrBuilder;
const walkAstIntoBuilder = @import("walk.zig").walkAstIntoBuilder;

const underline_code = "\x1b[4m";
const reset_code = "\x1b[0m";

pub fn walkAstWithRuntime(
    user_file_name: []const u8,
    should_optim: bool,
    io: std.Io,
    alloc: std.mem.Allocator,
) !Program {
    var irBuilder = try IrBuilder.init(alloc);
    defer irBuilder.deinit(alloc);
    errdefer irBuilder.program.deinit(alloc);
    // iterate through files in runtime/*
    const runtime_obj = try readFile("src/runtime/print.py", false, should_optim, io, alloc);
    try walkAstIntoBuilder(runtime_obj, &irBuilder, alloc);

    // walk UserFile
    const user_obj = try readFile(user_file_name, true, should_optim, io, alloc);
    try walkAstIntoBuilder(user_obj, &irBuilder, alloc);
    return irBuilder.program;
}

// file system stuff
fn readFile(
    file_name: []const u8,
    is_user_program: bool,
    should_optim: bool,
    io: std.Io,
    alloc: std.mem.Allocator,
) !*PyObject {
    const code = try std.Io.Dir.cwd().readFileAlloc(io, file_name, alloc, .limited(1 << 20));
    const code_z = try alloc.dupeSentinel(u8, code, 0);

    const ast_module = c.PyImport_ImportModule("ast");

    if (is_user_program) {
        std.debug.print("{s}running program:{s}", .{ underline_code, reset_code });
        if (should_optim) std.debug.print(" (OPTIM={})", .{should_optim});
        std.debug.print("\n\n{s}", .{code});
    }

    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code_z.ptr);
    std.debug.assert(tree != null);
    return tree;
}
