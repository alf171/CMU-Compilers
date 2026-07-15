const std = @import("std");
const debugPrint = std.debug.print;
const ArrayList = std.ArrayList;
const BasicBlock = @import("ir.zig").BasicBlock;
const Function = @import("ir.zig").Function;
const FunctionType = @import("ir.zig").FunctionType;
const Param = @import("alloc.zig").Param;

pub const Program = struct {
    main: Function,
    functions: ArrayList(Function),

    pub fn init(alloc: std.mem.Allocator) !Program {
        var blocks = ArrayList(BasicBlock).empty;
        const entry = BasicBlock.init(0);
        try blocks.append(alloc, entry);

        return Program{
            .main = Function{
                .name = try alloc.dupe(u8, "main"),
                .id = 0,
                .blocks = blocks,
                .entry_block = 0,
                .params = try alloc.alloc(Param, 0),
                .return_type = .i64,
                .next_temp = 0,
                .next_mem = 0,
                .origin = .runtime,
                .kind = .host,
            },
            .functions = .empty,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.main.deinit(alloc);
        for (self.functions.items) |*func| {
            func.deinit(alloc);
        }
        self.functions.deinit(alloc);
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
