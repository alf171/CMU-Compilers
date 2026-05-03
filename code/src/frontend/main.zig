const std = @import("std");
const c = @import("python.zig").c;
const walkAst = @import("walk.zig").walkAst;

pub fn main(init: std.process.Init) void {
    c.Py_Initialize();

    const alloc = init.gpa;
    const code: [*:0]const u8 = "x = 1 + 2";

    const ast_module = c.PyImport_ImportModule("ast");
    const parse_fn = c.PyObject_GetAttrString(ast_module, "parse");
    const tree = c.PyObject_CallFunction(parse_fn, "s", code);
    std.debug.assert(tree != null);

    walkAst(tree, alloc);
    // shutdown interpreter
    _ = c.Py_FinalizeEx();
}
