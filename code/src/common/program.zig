const std = @import("std");
const debugPrint = std.debug.print;
const ArrayList = std.ArrayList;
const BasicBlock = @import("ir.zig").BasicBlock;
const Function = @import("ir.zig").Function;

pub const Program = struct {
    main: Function,
    functions: ArrayList(Function),

    pub fn init(alloc: std.mem.Allocator) !Program {
        var blocks = ArrayList(BasicBlock).empty;
        const entry = BasicBlock.init(0);
        try blocks.append(alloc, entry);

        return Program{
            .main = Function{
                .name = "main",
                .id = 0,
                .blocks = blocks,
                .entry_block = 0,
                .params = &.{},
                .return_type = .{ .int = .i64 },
                .next_temp = 0,
                .next_mem = 0,
            },
            .functions = .empty,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.main.blocks.items) |*block| {
            for (block.instructions.items) |*instruction| {
                switch (instruction.*) {
                    .lir => |l| {
                        switch (l) {
                            .store_local => |sl| alloc.free(sl.local.name),
                            .load_local => |ll| alloc.free(ll.local.name),
                            else => {},
                        }
                    },
                    .phi => |phi| {
                        alloc.free(phi.inputs);
                    },
                    else => {},
                }
            }
            block.instructions.deinit(alloc);
            block.successors.deinit(alloc);
        }
        self.main.blocks.deinit(alloc);
    }

    pub fn print(self: @This()) !void {
        for (self.functions.items) |function| {
            debugPrint("\n{s} -> {s}:\n", .{ function.name, @tagName(function.return_type) });
            for (function.blocks.items) |block| {
                debugPrint("block{d}:\n", .{block.id});

                for (block.instructions.items) |*instruction| {
                    debugPrint("  ", .{});
                    try instruction.printFn();
                }
            }
        }
        debugPrint("\n{s} -> {s}:\n", .{ self.main.name, @tagName(self.main.return_type) });
        for (self.main.blocks.items) |block| {
            debugPrint("block{d}:\n", .{block.id});

            for (block.instructions.items) |*instruction| {
                debugPrint("  ", .{});
                try instruction.printFn();
            }
        }
    }
};
