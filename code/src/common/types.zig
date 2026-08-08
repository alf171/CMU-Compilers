const std = @import("std");
pub const RegisterType = @import("register.zig").RegisterType;
pub const FunctionKind = @import("ir.zig").FunctionKind;
pub const ClassId = @import("ir.zig").ClassId;

pub const TypeVarId = u32;

pub const TypeBindings = std.AutoHashMap(TypeVarId, TypeInfo);

pub const ClassInstance = struct {
    class_id: ClassId,
    /// used for generics
    args: []const TypeInfo,
};

// use a pointer on element type for recursive purposes
// things like range dont know their size at comptime
pub const TypeInfo = union(enum) {
    void,
    i64,
    i32,
    float,
    bool,
    char,
    /// size is stored in runtime header
    list: struct {
        element: *const TypeInfo,
    },
    tuple: struct {
        elements: []const TypeInfo,
    },
    iterable: struct {
        element: *const TypeInfo,
    },
    lazy: struct {
        value: *const TypeInfo,
    },
    // struct currently not needed
    ptr,
    // model a function in type system
    callable: struct {
        params: []const TypeInfo,
        returns: *const TypeInfo,
    },
    instance: ClassInstance,
    type_variable: TypeVarId,
    any,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        switch (self) {
            .list => |list| {
                list.element.*.deinit(alloc);
                alloc.destroy(@constCast(list.element));
            },
            .tuple => |tuple| {
                for (tuple.elements) |elem| {
                    elem.deinit(alloc);
                }
                alloc.free(tuple.elements);
            },
            .iterable => |iterable| {
                iterable.element.*.deinit(alloc);
                alloc.destroy(@constCast(iterable.element));
            },
            .lazy => |lazy| {
                lazy.value.*.deinit(alloc);
                alloc.destroy(@constCast(lazy.value));
            },
            .callable => |callable| {
                for (callable.params) |param| {
                    param.deinit(alloc);
                }
                alloc.free(callable.params);

                callable.returns.*.deinit(alloc);
                alloc.destroy(@constCast(callable.returns));
            },
            .instance => |instance| {
                for (instance.args) |arg| {
                    arg.deinit(alloc);
                }
                alloc.free(instance.args);
            },
            else => {},
        }
    }

    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {
        switch (self) {
            .tuple => |t| {
                const elements = try alloc.alloc(TypeInfo, t.elements.len);
                errdefer alloc.free(elements);

                for (t.elements, 0..) |elem, i| {
                    elements[i] = try elem.clone(alloc);
                }
                return .{ .tuple = .{ .elements = elements } };
            },
            .list => |l| {
                return .{ .list = .{
                    .element = try (try l.element.*.clone(alloc)).toOwnedPointer(alloc),
                } };
            },
            .callable => |c| {
                var params = try alloc.alloc(TypeInfo, c.params.len);
                for (c.params, 0..) |param, i| {
                    params[i] = try param.clone(alloc);
                }
                return .{ .callable = .{
                    .params = params,
                    .returns = try (try c.returns.*.clone(alloc)).toOwnedPointer(alloc),
                } };
            },
            .lazy => |l| {
                return .{ .lazy = .{
                    .value = try (try l.value.*.clone(alloc)).toOwnedPointer(alloc),
                } };
            },
            .iterable => |i| {
                return .{ .iterable = .{
                    .element = try (try i.element.*.clone(alloc)).toOwnedPointer(alloc),
                } };
            },
            .instance => |instance| {
                var args = try alloc.alloc(TypeInfo, instance.args.len);
                var initialized: usize = 0;
                errdefer {
                    for (args[0..initialized]) |t| t.deinit(alloc);
                    alloc.free(args);
                }
                for (instance.args, 0..) |arg, i| {
                    args[i] = try arg.clone(alloc);
                    initialized += 1;
                }

                return .{ .instance = .{
                    .class_id = instance.class_id,
                    .args = args,
                } };
            },
            .void, .i64, .i32, .bool, .char, .float, .any, .type_variable, .ptr => return self,
            // else => |e| {
            //     std.debug.print("clone does support {s}\n", .{@tagName(e)});
            //     return error.NotImpl;
            // },
        }
    }

    pub fn sizeOfType(self: @This()) !usize {
        return switch (self) {
            // instances are just pointers
            .instance => 8,
            .i64, .list, .tuple, .ptr, .float => 8,
            .i32 => 4,
            .bool, .char => 1,
            else => |e| {
                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        };
    }

    /// expects a list input type
    pub fn getElementType(typeInfo: TypeInfo) !TypeInfo {
        return switch (typeInfo) {
            .list => |list_type| list_type.element.*,
            .iterable => |it_type| it_type.element.*,
            .lazy => |lazy| try getElementType(lazy.value.*),
            else => error.ExpectedListType,
        };
    }

    pub fn getElementSize(typeInfo: TypeInfo) ?usize {
        return switch (typeInfo) {
            .array => |array_type| array_type.size,
            else => error.ExpectedArrayType,
        };
    }

    pub fn isIterable(self: @This()) bool {
        return switch (self) {
            .list, .tuple, .iterable, .any => true,
            .lazy => |lazy| isIterable(lazy.value.*),
            else => false,
        };
    }

    pub fn equal(self: @This(), other: @This()) bool {
        return std.meta.activeTag(self) == std.meta.activeTag(other);
    }

    pub fn toRegisterType(self: @This(), function_kind: FunctionKind) RegisterType {
        return switch (function_kind) {
            .host => switch (self) {
                .float => .f,
                else => return .gp,
            },
            .gpu_kernel => .vgpr,
        };
    }

    pub fn toOwnedPointer(self: TypeInfo, alloc: std.mem.Allocator) !*TypeInfo {
        const ptr = try alloc.create(TypeInfo);
        ptr.* = self;
        return ptr;
    }

    /// verifies generics logic
    pub fn unify(self: @This(), expected: TypeInfo, bindings: *TypeBindings, alloc: std.mem.Allocator) !void {
        switch (self) {
            .type_variable => |tv| {
                if (bindings.get(tv)) |resolves| {
                    if (!resolves.equal(expected)) return error.TypeMismatch;
                    return;
                }
                try bindings.put(tv, try expected.clone(alloc));
            },
            .list => |generic_l| switch (expected) {
                .list => |expected_l| {
                    try unify(generic_l.element.*, expected_l.element.*, bindings, alloc);
                },
                else => return error.TypeMistmatch,
            },
            .instance => |instance| switch (expected) {
                .instance => |expected_i| {
                    if (instance.class_id != expected_i.class_id) {
                        return error.TypeMismatch;
                    }
                    if (instance.args.len != expected_i.args.len) {
                        return error.TypeMismatch;
                    }
                    for (instance.args, expected_i.args) |actual_arg, expected_arg| {
                        try unify(actual_arg, expected_arg, bindings, alloc);
                    }
                },
                else => return error.TypeMistmatch,
            },
            .tuple => return error.NotImpl,
            else => {},
        }
    }

    /// returns generics evaluate type
    pub fn substitute(self: @This(), bindings: *TypeBindings, alloc: std.mem.Allocator) !TypeInfo {
        switch (self) {
            .type_variable => |t| {
                const actual = bindings.get(t) orelse {
                    return error.ExpectedBinding;
                };
                return try actual.clone(alloc);
            },
            .list => |l| {
                const elem = try substitute(l.element.*, bindings, alloc);
                return .{ .list = .{ .element = try elem.toOwnedPointer(alloc) } };
            },
            .instance => |i| {
                var args = try alloc.alloc(TypeInfo, i.args.len);
                var initialized: usize = 0;
                errdefer {
                    for (args[0..initialized]) |arg| {
                        arg.deinit(alloc);
                    }
                    alloc.free(args);
                }
                for (i.args, 0..) |arg, arg_i| {
                    args[arg_i] = try arg.substitute(bindings, alloc);
                    initialized += 1;
                }

                return .{ .instance = .{
                    .class_id = i.class_id,
                    .args = args,
                } };
            },
            else => return try self.clone(alloc),
        }
    }

    pub fn toString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .i64 => try alloc.dupe(u8, "i64"),
            .i32 => try alloc.dupe(u8, "i32"),
            .bool => try alloc.dupe(u8, "bool"),
            .char => try alloc.dupe(u8, "char"),
            .float => try alloc.dupe(u8, "float"),
            .list => |l| blk: {
                const elem = try l.element.*.toString(alloc);
                defer alloc.free(elem);

                break :blk try std.fmt.allocPrint(alloc, "list_{s}", .{elem});
            },
            else => |e| {
                std.debug.print("cannot stringify type {s}\n", .{@tagName(e)});
                return error.TypeStringNotImpl;
            },
        };
    }
};

test "unify + sub" {}
