const std = @import("std");

// use a pointer on element type for recursive purposes
// things like range dont know their size at comptime
pub const TypeInfo = union(enum) {
    void,
    int: union(enum) {
        i64,
        i32,
    },
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
            .void, .int, .bool, .char, .float => return self,
            else => |e| {
                std.debug.print("clone does support {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
    }

    pub fn sizeOfType(self: @This()) !usize {
        return switch (self) {
            .bool, .char => 1,
            .int => |i| switch (i) {
                .i64 => 8,
                .i32 => 4,
            },
            .list => 8,
            .tuple => 8,
            else => error.NotImpl,
        };
    }

    pub fn isIterable(self: @This()) bool {
        return switch (self) {
            .list, .tuple, .iterable, .any => true,
            .lazy => |lazy| isIterable(lazy.value.*),
            else => false,
        };
    }

    pub fn equal(self: @This(), other: @This()) !bool {
        switch (self) {
            // int32 == int64...
            .int => return other == .int,
            .void => return other == .void,
            .float => return other == .float,
            .bool => return other == .bool,
            .char => return other == .char,
            else => |e| {
                std.debug.print("equal doesnt support {s}\n", .{@tagName(e)});
                return error.NotImpl;
            },
        }
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
