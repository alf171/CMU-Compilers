const std = @import("std");

const underline_code = "\x1b[4m";
const reset_code = "\x1b[0m";

const Phase = enum {
    frontend_total,
    middle_total,
    middle_liveness,
    middle_igraph,
    middle_color,
    middle_spill_reg,
    middle_coalesce,
    middle_reg_class,
    middle_reg_alloc_build,
    backend_total,
};

pub const TimerMetrics = struct {
    durations: std.EnumArray(Phase, std.Io.Duration),
    invocations: std.EnumArray(Phase, usize),
    starts: std.EnumArray(Phase, ?std.Io.Timestamp),

    pub fn init() @This() {
        return .{
            .durations = .initFill(.zero),
            .invocations = .initFill(0),
            .starts = .initFill(null),
        };
    }

    pub fn begin(self: *@This(), phase: Phase, io: std.Io) void {
        std.debug.assert(self.starts.get(phase) == null);
        self.starts.set(phase, std.Io.Clock.awake.now(io));
    }

    pub fn finish(
        self: *@This(),
        phase: Phase,
        io: std.Io,
    ) void {
        const end = std.Io.Clock.awake.now(io);
        const start = self.starts.get(phase) orelse @panic("timer wasn't started");
        const duration = start.durationTo(end);
        self.durations.getPtr(phase).nanoseconds += duration.nanoseconds;
        self.invocations.getPtr(phase).* += 1;
        self.starts.set(phase, null);
    }

    pub fn print(self: *const @This(), use_escape_codes: bool) void {
        std.debug.print("\n", .{});
        if (use_escape_codes) std.debug.print("{s}", .{underline_code});
        std.debug.print("timer metrics:", .{});
        if (use_escape_codes) std.debug.print("{s}\n", .{reset_code});
        inline for (std.meta.tags(Phase)) |phase| {
            const elapsed = self.durations.get(phase);
            const calls = self.invocations.get(phase);

            const milliseconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1_000_000.0;

            std.debug.print("{s} {d:.3} ms ({d} calls)\n", .{ @tagName(phase), milliseconds, calls });
        }
    }
};
