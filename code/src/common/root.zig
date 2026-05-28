const std = @import("std");

pub const ir = @import("ir.zig");
pub const alloc = @import("alloc.zig");
pub const types = @import("types.zig");

test {
    std.testing.refAllDecls(@This());
}
