const std = @import("std");
const debugPrint = std.debug.print;
const ArrayList = std.ArrayList;
const BasicBlock = @import("ir.zig").BasicBlock;
const Function = @import("ir.zig").Function;
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
                .return_type = .{ .int = .i64 },
                .next_temp = 0,
                .next_mem = 0,
            },
            .functions = .empty,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        deinitFunction(&self.main, alloc);
        for (self.functions.items) |*func| {
            deinitFunction(func, alloc);
        }

        self.functions.deinit(alloc);
    }

    fn deinitFunction(function: *Function, alloc: std.mem.Allocator) void {
        for (function.blocks.items) |*block| {
            for (block.instructions.items) |*instruction| {
                instruction.deinit(alloc);
            }
            block.instructions.deinit(alloc);
            block.successors.deinit(alloc);
        }
        function.blocks.deinit(alloc);
        // function metadata
        function.return_type.deinit(alloc);
        alloc.free(function.name);
        for (function.params) |param| {
            alloc.free(param.name);
            param.type.deinit(alloc);
        }
        alloc.free(function.params);
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
