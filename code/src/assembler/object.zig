const std = @import("std");

pub const SectionKind = enum {
    text,
    rodata,
};

pub const Section = struct {
    contents: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Section, alloc: std.mem.Allocator) void {
        self.contents.deinit(alloc);
    }
};

pub const Binding = enum {
    local,
    global,
};

pub const Symbol = struct {
    name: []const u8,
    binding: Binding,
    section_kind: ?SectionKind = null,
    offset: u32 = 0,

    pub fn deinit(self: *Symbol, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub const FixUps = struct {
    section: SectionKind,
    offset: u32,
    symbol_index: u32,
};

const Self = @This();

sections: std.EnumArray(SectionKind, ?Section),
symbols: std.ArrayList(Symbol),
fixups: std.ArrayList(FixUps),

pub fn init() Self {
    return .{
        .sections = .initFill(null),
        .symbols = .empty,
        .fixups = .empty,
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    var it = self.sections.iterator();
    while (it.next()) |entry| {
        if (entry.value.*) |*section| {
            section.deinit(alloc);
        }
    }
    for (self.symbols.items) |*symbol| {
        symbol.deinit(alloc);
    }
    self.symbols.deinit(alloc);
    self.fixups.deinit(alloc);
}

pub fn getOrCreateSection(self: *Self, kind: SectionKind) *Section {
    const section = self.sections.getPtr(kind);
    if (section.* == null) {
        section.* = .{};
    }

    return &section.*.?;
}

pub fn getOrCreateSymbol(self: *Self, name: []const u8, alloc: std.mem.Allocator) !u32 {
    for (self.symbols.items, 0..) |symbol, i| {
        if (std.mem.eql(u8, name, symbol.name)) {
            return @intCast(i);
        }
    }

    const index: u32 = @intCast(self.symbols.items.len);
    try self.symbols.append(alloc, .{
        .name = try alloc.dupe(u8, name),
        .binding = .local,
    });
    return index;
}
