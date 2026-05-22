const std = @import("std");

pub const ir = @import("ir.zig");
pub const alloc = @import("alloc.zig");

test {
    std.testing.refAllDecls(@This());
}
