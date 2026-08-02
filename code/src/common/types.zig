const std = @import("std");
pub const RegisterType = @import("register.zig").RegisterType;
pub const FunctionKind = @import("ir.zig").FunctionKind;
pub const ClassId = @import("ir.zig").ClassId;

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
    instance: ClassId,
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
            .void, .i64, .i32, .bool, .char, .float, .any, .instance => return self,
            else => |e| {
                std.debug.print("clone does support {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
    }

    pub fn sizeOfType(self: @This()) !usize {
        return switch (self) {
            // instances are just pointers
            .instance => 8,
            .i64, .list, .tuple, .ptr => 8,
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
};
