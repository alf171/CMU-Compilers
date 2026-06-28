pub const Abi = struct {
    function_param_regs: []const []const u8,

    /// checks if index provided is in bounds
    pub fn getIndex(self: @This(), index: usize) !u8 {
        if (index >= self.function_param_regs.len) return error.OutOfBounds;

        return @intCast(index);
    }

    /// convert an index into a register
    pub fn paramRegFor(self: @This(), index: usize) ![]const u8 {
        return switch (index) {
            0...7 => |i| self.function_param_regs[i],
            else => error.TooManyArgs,
        };
    }
};
