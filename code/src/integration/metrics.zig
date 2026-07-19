const std = @import("std");
const FunctionType = @import("common").ir.FunctionType;
const Target = @import("backend").Target;

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
    origin: FunctionType,

    pub fn init(origin: FunctionType, spill_count: usize) @This() {
        return Metrics{
            .line_count = 0,
            .mov_count = 0,
            .memory_load_count = 0,
            .memory_store_count = 0,
            .branches = 0,
            .calls = 0,
            .spill_count = spill_count,
            .origin = origin,
        };
    }

    pub fn print(self: @This(), use_escape_codes: bool) void {
        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("performance report:", .{});
        if (use_escape_codes) std.debug.print("{s}", .{reset_code});
        std.debug.print(" (ORIGIN={s})\n", .{@tagName(self.origin)});
        std.debug.print("number of asm lines: {d}\n", .{self.line_count});
        std.debug.print("mov count: {d}\n", .{self.mov_count});
        std.debug.print("memory load count: {d}\n", .{self.memory_load_count});
        std.debug.print("memory store count: {d}\n", .{self.memory_store_count});
        std.debug.print("branch count: {d}\n", .{self.branches});
        std.debug.print("call count: {d}\n", .{self.calls});
        std.debug.print("spill count: {d}\n", .{self.spill_count});
    }
};

pub const MetricsReport = struct {
    user: Metrics,
    runtime: Metrics,
};

pub fn get(
    asm_text: []const u8,
    spill_counts: std.EnumArray(FunctionType, usize),
    target: Target,
) MetricsReport {
    var current_origin: FunctionType = .user;
    var runtime_metrics = Metrics.init(.runtime, spill_counts.get(.runtime));
    var user_metrics = Metrics.init(.user, spill_counts.get(.user));
    var lines = std.mem.splitScalar(u8, asm_text, '\n');
    while (lines.next()) |line| {
        const trim = std.mem.trim(u8, line, "\t");

        if (std.mem.endsWith(u8, trim, "origin: user")) {
            current_origin = .user;
            continue;
        }
        if (std.mem.endsWith(u8, trim, "origin: runtime")) {
            current_origin = .runtime;
            continue;
        }

        const current = switch (current_origin) {
            .runtime => &runtime_metrics,
            .user => &user_metrics,
        };

        if (trim.len == 0) continue;

        if (trim[0] == '.' or trim[0] == '_') continue;

        current.line_count += 1;
        switch (target.host) {
            .ARM => {
                if (std.mem.startsWith(u8, trim, "mov")) current.mov_count += 1;
                if (std.mem.startsWith(u8, trim, "ldr")) current.memory_load_count += 1;
                if (std.mem.startsWith(u8, trim, "str")) current.memory_store_count += 1;
                if (std.mem.startsWith(u8, trim, "ret") or std.mem.startsWith(u8, trim, "b ")) current.branches += 1;
                if (std.mem.startsWith(u8, trim, "bl")) current.calls += 1;
            },
            .X86 => {
                if (std.mem.startsWith(u8, trim, "mov")) current.mov_count += 1;
                if (std.mem.startsWith(u8, trim, "j") or std.mem.startsWith(u8, trim, "ret")) current.branches += 1;
                if (std.mem.startsWith(u8, trim, "call")) current.calls += 1;
            },
            .UNKNOWN => unreachable,
        }
    }

    return .{
        .runtime = runtime_metrics,
        .user = user_metrics,
    };
}
