const std = @import("std");

const underline_code = "\x1b[4m";
const reset_code = "\x1b[0m";

pub const Metrics = struct {
    line_count: usize,
    mov_count: usize,
    memory_load_count: usize,
    memory_store_count: usize,
    branches: usize,
    calls: usize,
    spill_count: usize,

    pub fn print(self: @This(), use_escape_codes: bool) void {
        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("performance report:", .{});
        if (use_escape_codes) std.debug.print("{s}", .{reset_code});
        std.debug.print("\nnumber of asm lines: {d}\n", .{self.line_count});
        std.debug.print("mov count: {d}\n", .{self.mov_count});
        std.debug.print("memory load count: {d}\n", .{self.memory_load_count});
        std.debug.print("memory store count: {d}\n", .{self.memory_store_count});
        std.debug.print("branch count: {d}\n", .{self.branches});
        std.debug.print("call count: {d}\n", .{self.calls});
        std.debug.print("spill count: {d}\n", .{self.spill_count});
    }
};

pub fn get(asm_text: []u8, spill_count: usize) Metrics {
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

    return Metrics{
        .line_count = line_count,
        .mov_count = mov_count,
        .memory_load_count = memory_load_count,
        .memory_store_count = memory_store_count,
        .branches = branches,
        .calls = calls,
        .spill_count = spill_count,
    };
}
