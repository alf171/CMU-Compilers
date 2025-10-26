const std = @import("std");
const c = @cImport({
    @cInclude("Python.h");
});

pub fn main() void {
    c.Py_Initialize();

    const code: [*:0]const u8 = "x = 1 + 2";
    const filename: [*:0]const u8 = "<zig>";

    const ast_mod = c.Py_CompileString(code, filename, c.Py_file_input);
    if (ast_mod == null) {
        std.debug.print("Parse failed\n", .{});
    } else {
        std.debug.print("Got code object: {*}\n", .{ast_mod});
    }

    _ = c.Py_FinalizeEx();
}

// fetch .body
// loop through stmts
pub fn walk_ast(obj: ?*c.PyObject) void {
    if (obj == null) return;

    const body = c.PyObject_GetAttrString(obj, "body");
    const n = c.PyList_Size(body);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const stmt = c.PyList_GetItem(body, i);
        // stmt: assign
        // expr: BinOp, Constant, Name
    }
}
