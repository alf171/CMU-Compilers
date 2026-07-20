const std = @import("std");
pub const RegisterType = @import("ir.zig").RegisterType;

// use a pointer on element type for recursive purposes
// things like range dont know their size at comptime
pub const TypeInfo = union(enum) {
    void,
    i64,
    i32,
    float,
    bool,
    char,
    list: struct {
        element: *const TypeInfo,
        size: ?usize,
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
                    .element = try ownedPointer(try l.element.*.clone(alloc), alloc),
                    .size = l.size,
                } };
            },
            .callable => |c| {
                var params = try alloc.alloc(TypeInfo, c.params.len);
                for (c.params, 0..) |param, i| {
                    params[i] = try param.clone(alloc);
                }
                return .{ .callable = .{
                    .params = params,
                    .returns = try ownedPointer(try c.returns.*.clone(alloc), alloc),
                } };
            },
            .lazy => |l| {
                return .{ .lazy = .{
                    .value = try ownedPointer(try l.value.*.clone(alloc), alloc),
                } };
            },
            .iterable => |i| {
                return .{ .iterable = .{
                    .element = try ownedPointer(try i.element.*.clone(alloc), alloc),
                } };
            },
            .void, .i64, .i32, .bool, .char, .float, .any => return self,
            else => |e| {
                std.debug.print("clone does support {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
    }

    pub fn sizeOfType(self: @This()) !usize {
        return switch (self) {
            .i64, .list, .tuple, .ptr => 8,
            .i32 => 4,
            .bool, .char => 1,
            else => |e| {
                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
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

    pub fn toCpuRegisterType(self: @This()) RegisterType {
        return switch (self) {
            .float => .f,
            else => return .gp,
        };
    }
};

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

pub fn ownedPointer(t: TypeInfo, alloc: std.mem.Allocator) !*TypeInfo {
    const ptr = try alloc.create(TypeInfo);
    ptr.* = t;
    return ptr;
}
