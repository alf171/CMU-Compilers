const std = @import("std");
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Operand = @import("common").alloc.Operand;
const RegisterType = @import("common").register.RegisterType;
const RegisterClasses = @import("common").register.RegisterClasses;

/// going to select RegisterType in its own pass via a Map<Op, RegType> result
pub fn classify(program: Program, alloc: std.mem.Allocator) !RegisterClasses {
    var res = RegisterClasses.init(alloc);
    try classifyFunction(program.main, &res);
    for (program.functions.items) |function| {
        try classifyFunction(function, &res);
    }
    return res;
}

fn classifyFunction(
    function: Function,
    classes: *RegisterClasses,
) !void {
    for (function.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            const define = instruction.getDefines() orelse continue;

            const value = switch (define) {
                .top => |top| top,
                .local => continue,
            };

            const register_type: RegisterType = switch (function.kind) {
                .host => value.type.toRegisterType(.host),
                .gpu_kernel => switch (instruction) {
                    .function_param => .sgpr,
                    else => .vgpr,
                },
            };
            try classes.put(value.operand, register_type);
        }
    }
}
