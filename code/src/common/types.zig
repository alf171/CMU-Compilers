pub const TypeInfo = union(enum) {
    int,
    float,
    bool,
    char,
    list: struct {
        element: *const TypeInfo,
    },
    array: struct {
        element: *const TypeInfo,
        // TODO: make required
        size: ?usize,
    },
};

pub const int_type: TypeInfo = .int;
pub const bool_type: TypeInfo = .bool;

pub fn listElementType(typeInfo: TypeInfo) !TypeInfo {
    return switch (typeInfo) {
        .list => |list_type| list_type.element.*,
        .array => |array_type| array_type.element.*,
        else => error.ExpectedListType,
    };
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
