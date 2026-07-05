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
    any,

    pub fn sizeOfType(self: TypeInfo) !usize {
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
            else => false,
        };
    }
};

/// expects a list input type
pub fn getElementType(typeInfo: TypeInfo) !TypeInfo {
    return switch (typeInfo) {
        .list => |list_type| list_type.element.*,
        .iterable => |it_type| it_type.element.*,
        .tuple => .any,
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
