const std = @import("std");
const HashMap = std.AutoHashMap;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const Param = @import("common").alloc.Param;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;

/// sets default params
pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    var function_params = std.StringHashMap([]Param).init(alloc);
    defer function_params.deinit();
    for (program.functions.items) |*function| {
        try function_params.put(function.name, function.params);
    }

    try rewriteFunction(&program.main, &function_params, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(function, &function_params, alloc);
    }
}

fn rewriteFunction(
    function: *Function,
    function_params: *std.StringHashMap([]Param),
    alloc: std.mem.Allocator,
) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .function_call => |fc| {
                    const fun_name = switch (fc.callee) {
                        .direct => |name| name,
                        .indirect => {
                            try new_instructions.append(alloc, instruction.*);
                            continue;
                        },
                    };

                    const params = function_params.get(fun_name) orelse {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    };
                    // no defaults
                    if (fc.args.len == params.len) {
                        try new_instructions.append(alloc, instruction.*);
                        continue;
                    }
                    var new_args = try alloc.alloc(TypedOperand, params.len);
                    errdefer alloc.free(new_args);

                    // fill new_args
                    @memcpy(new_args[0..fc.args.len], fc.args);
                    for (params[fc.args.len..], fc.args.len..) |param, i| {
                        const default = param.default orelse {
                            return error.ExpectedDefault;
                        };

                        const default_arg: TypedOperand = .{
                            .operand = function.nextTemp(),
                            .type = default.toType(),
                        };
                        try new_instructions.append(alloc, .{ .lir = .{ .move = .{
                            .dst = default_arg,
                            .src = .{ .constant = default },
                        } } });
                        new_args[i] = default_arg;
                    }

                    try new_instructions.append(alloc, .{ .function_call = .{
                        .dst = if (fc.dst) |dst| try dst.clone(alloc) else null,
                        .args = new_args,
                        .callee = fc.callee,
                    } });
                    instruction.deinit(alloc);
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}
