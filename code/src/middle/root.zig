pub const loop = @import("loop.zig");
pub const reg_alloc = @import("reg_alloc.zig");
pub const live = @import("live.zig");
pub const igraph = @import("igraph.zig");
pub const color = @import("color.zig");
pub const phi = @import("phi.zig");
pub const parallel_copies = @import("parallel_copies.zig");
pub const copy = @import("optim/copy.zig");
pub const dead = @import("optim/dead.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
