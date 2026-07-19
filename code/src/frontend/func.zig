const std = @import("std");
const HashMap = std.AutoHashMap;
const TypedOperand = @import("common").alloc.TypedOperand;
const Function = @import("common").ir.Function;
const FunctionCallInst = @import("common").mir.FunctionCallInst;
const FunctionCallee = @FieldType(FunctionCallInst, "callee");
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

    try rewriteFunction(program, &program.main, &function_params, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(program, function, &function_params, alloc);
    }
}

fn rewriteFunction(
    program: *Program,
    function: *Function,
    function_params: *std.StringHashMap([]Param),
    alloc: std.mem.Allocator,
) !void {
    for (function.blocks.items) |*block| {
        var new_instructions = std.ArrayList(Instruction).empty;
        errdefer new_instructions.deinit(alloc);

        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                // not cleanest impl
                .function_call => |fc| {
                    const kernel_success = try gpuKernelRewrite(fc, &new_instructions, program, alloc);
                    if (kernel_success) {
                        instruction.deinit(alloc);
                        continue;
                    }

                    const default_success = try defaultParamRewrite(fc, &new_instructions, instruction.*, function, function_params, alloc);
                    if (default_success) {
                        instruction.deinit(alloc);
                        continue;
                    }
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

fn defaultParamRewrite(
    fc: FunctionCallInst,
    new_instructions: *std.ArrayList(Instruction),
    instruction: Instruction,
    function: *Function,
    function_params: *std.StringHashMap([]Param),
    alloc: std.mem.Allocator,
) !bool {
    const fun_name = switch (fc.callee) {
        .direct => |name| name,
        .indirect => {
            try new_instructions.append(alloc, instruction);
            return false;
        },
    };

    const params = function_params.get(fun_name) orelse {
        try new_instructions.append(alloc, instruction);
        return false;
    };
    // no missing args
    if (fc.args.len >= params.len) {
        try new_instructions.append(alloc, instruction);
        return false;
    }
    var new_args = try alloc.alloc(TypedOperand, params.len);
    errdefer alloc.free(new_args);

    // fill new_args
    for (fc.args, 0..) |arg, i| {
        new_args[i] = try arg.clone(alloc);
    }
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
        .callee = try fc.callee.clone(alloc),
    } });
    return true;
}

fn gpuKernelRewrite(
    fc: FunctionCallInst,
    new_instructions: *std.ArrayList(Instruction),
    program: *const Program,
    alloc: std.mem.Allocator,
) !bool {
    const callee_fn_name = switch (fc.callee) {
        .direct => |d| d,
        .indirect => return false,
    };
    // search program for function
    const target_function = blk: {
        for (program.functions.items) |func| {
            if (std.mem.eql(u8, func.name, callee_fn_name)) {
                break :blk func;
            }
        }
        return false;
    };

    if (target_function.kind != .gpu_kernel) {
        return false;
    }

    var new_args = try alloc.alloc(TypedOperand, fc.args.len);
    errdefer alloc.free(new_args);
    for (fc.args, 0..) |arg, i| {
        new_args[i] = try arg.clone(alloc);
    }

    try new_instructions.append(alloc, .{
        .function_call = .{
            .dst = null,
            .args = new_args,
            // .callee = .{ .direct = try alloc.dupe(u8, target_function.name) },
            .callee = .{ .direct = try alloc.dupe(u8, "gpu_launch") },
        },
    });
    return true;
}
