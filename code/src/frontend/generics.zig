const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const BasicBlock = @import("common").ir.BasicBlock;
const Operand = @import("common").alloc.Operand;
const TypedOperand = @import("common").alloc.TypedOperand;
const Param = @import("common").ir.Param;
const TypeParam = @import("common").ir.TypeParam;
const ValueRef = @import("common").ir.ValueRef;
const Function = @import("common").ir.Function;
const Program = @import("common").program.Program;
const Instruction = @import("common").mir.Instruction;
const TypeBindings = @import("common").types.TypeBindings;
const TypeInfo = @import("common").types.TypeInfo;

pub fn rewrite(program: *Program, alloc: std.mem.Allocator) !void {
    try rewriteFunction(program, &program.main, alloc);
    for (program.functions.items) |*function| {
        try rewriteFunction(program, function, alloc);
    }
    dropTemplates(program, alloc);
}

/// rewrite function distructively
fn rewriteFunction(program: *Program, function: *Function, alloc: std.mem.Allocator) !void {
    for (function.blocks.items) |*block| {
        var new_instructions: ArrayList(Instruction) = .empty;
        errdefer new_instructions.deinit(alloc);
        for (block.instructions.items) |*instruction| {
            switch (instruction.*) {
                .function_call => {
                    var new_instruction = instruction.*;
                    const fc = &new_instruction.function_call;
                    const callee_name = switch (fc.callee) {
                        .direct => |name| name,
                        else => {
                            try new_instructions.append(alloc, new_instruction);
                            continue;
                        },
                    };

                    const callee = findFunction(program, callee_name) orelse {
                        try new_instructions.append(alloc, new_instruction);
                        continue;
                    };
                    // check for generics
                    var bindings = TypeBindings.init(alloc);
                    defer {
                        var it = bindings.valueIterator();
                        while (it.next()) |_type| {
                            _type.deinit(alloc);
                        }
                        bindings.deinit();
                    }
                    // early return if we have no generics
                    if (callee.type_params.len == 0) {
                        try new_instructions.append(alloc, new_instruction);
                        continue;
                    }
                    // populate
                    for (callee.params, fc.args) |param, arg| {
                        try TypeInfo.unify(param.type, arg.type, &bindings, alloc);
                    }

                    const specialized_func_name = try createSpecializedFunctionName(
                        callee_name,
                        callee.type_params,
                        &bindings,
                        alloc,
                    );
                    errdefer alloc.free(specialized_func_name);

                    const return_type = try callee.return_type.substitute(&bindings, alloc);

                    if (findFunction(program, specialized_func_name) == null) {
                        const specialized_function = try createSpecializedFunction(
                            callee,
                            specialized_func_name,
                            program.functions.items.len + 1,
                            &bindings,
                            alloc,
                        );
                        try program.functions.append(alloc, specialized_function);
                    }

                    if (fc.dst) |*dst| {
                        dst.type.deinit(alloc);
                        dst.type = return_type;
                        try function.setValueType(dst.operand, dst.type, alloc);
                    } else {
                        return_type.deinit(alloc);
                    }

                    switch (fc.callee) {
                        .direct => |old_name| {
                            alloc.free(old_name);
                            fc.callee = .{ .direct = specialized_func_name };
                        },
                        .indirect => unreachable,
                    }

                    try new_instructions.append(alloc, new_instruction);
                },
                else => try new_instructions.append(alloc, instruction.*),
            }
        }
        block.instructions.deinit(alloc);
        block.instructions = new_instructions;
    }
}

fn createSpecializedFunctionName(
    base_name: []const u8,
    type_params: []TypeParam,
    bindings: *TypeBindings,
    alloc: std.mem.Allocator,
) ![]const u8 {
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, base_name);
    try out.appendSlice(alloc, "__");

    for (type_params, 0..) |type_param, i| {
        // append _ between composite generics for better readability
        if (i != 0) try out.appendSlice(alloc, "_");

        const bound_type = bindings.get(type_param.id) orelse return error.ExpectedBinding;
        const type_name = try bound_type.toString(alloc);
        defer alloc.free(type_name);
        try out.appendSlice(alloc, type_name);
    }

    return out.toOwnedSlice(alloc);
}

fn createSpecializedFunction(
    function: *const Function,
    specialized_name: []const u8,
    specialized_id: usize,
    bindings: *TypeBindings,
    alloc: std.mem.Allocator,
) !Function {
    var params = try alloc.alloc(Param, function.params.len);
    errdefer alloc.free(params);

    for (function.params, 0..) |param, i| {
        params[i] = .{
            .name = try alloc.dupe(u8, param.name),
            .type = try param.type.substitute(bindings, alloc),
            .default = if (param.default) |d| try d.clone(alloc) else null,
        };
    }

    const return_type = try function.return_type.substitute(bindings, alloc);

    var cloned = try Function.init(
        specialized_name,
        specialized_id,
        params,
        try alloc.alloc(TypeParam, 0),
        return_type,
        function.origin,
        function.kind,
        alloc,
    );
    errdefer cloned.deinit(alloc);

    // deinit init'd stuff
    cloned.blocks.items[0].deinit(alloc);
    cloned.blocks.clearRetainingCapacity();

    for (function.blocks.items) |source| {
        var block = BasicBlock.init(source.id);
        errdefer block.deinit(alloc);
        try block.successors.appendSlice(alloc, source.successors.items);

        for (source.instructions.items) |*source_instruct| {
            var instruct = try source_instruct.clone(alloc);
            errdefer instruct.deinit(alloc);
            try instruct.remapInstruction(specialized_id, bindings, alloc);
            try block.instructions.append(alloc, instruct);
        }
        try cloned.blocks.append(alloc, block);
    }

    cloned.entry_block = function.entry_block;
    cloned.next_temp = function.next_temp;
    cloned.next_mem = function.next_mem;

    return cloned;
}

// TODO: find somewhere more generic to put this
fn findFunction(program: *const Program, function_name: []const u8) ?*Function {
    for (program.functions.items) |*function| {
        if (std.mem.eql(u8, function.name, function_name)) {
            return function;
        }
    }
    return null;
}

fn dropTemplates(program: *Program, alloc: std.mem.Allocator) void {
    var write_index: usize = 0;
    for (program.functions.items, 0..) |*function, read_index| {
        if (function.type_params.len > 0) {
            function.deinit(alloc);
            continue;
        }

        if (read_index != write_index) {
            program.functions.items[write_index] = function.*;
        }
        write_index += 1;
    }
    program.functions.items.len = write_index;
}
