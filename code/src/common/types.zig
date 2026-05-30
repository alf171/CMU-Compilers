const std = @import("std");

pub const TypeInfo = union(enum) {
    int,
    float,
    bool,
    char,
    list: struct {
        element: *const TypeInfo,
        // TODO: this shouldnt be needed
        size: ?usize,
    },
    array: struct {
        element: *const TypeInfo,
        // TODO: make required
        size: ?usize,
    },
};

pub fn getElementType(typeInfo: TypeInfo) !TypeInfo {
    return switch (typeInfo) {
        .list => |list_type| list_type.element.*,
        .array => |array_type| array_type.element.*,
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

pub fn sizeOfType(t: TypeInfo) !usize {
    return switch (t) {
        .bool, .char => 1,
        .int => 8,
        .list => 8,
        .array => 8,
        else => error.NotImpl,
    };
}
