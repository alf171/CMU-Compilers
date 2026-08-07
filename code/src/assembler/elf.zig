const std = @import("std");
const ArrayList = std.ArrayList;
const Target = @import("backend").Target;
const AssemblerRequest = @import("shared.zig").AssemblerRequest;
const Object = @import("object.zig");
const x86_assemble = @import("x86.zig").assemble;
const Ehdr = std.elf.Elf64.Ehdr;
const Shdr = std.elf.Elf64.Shdr;
const Sym = std.elf.Elf64.Sym;

pub fn run(request: AssemblerRequest, io: std.Io, alloc: std.mem.Allocator) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        request.input_file,
        alloc,
        .limited(1 << 20),
    );
    defer alloc.free(source);

    // going to just impl x86
    var object = switch (request.target.host) {
        .X86 => try x86_assemble(source, alloc),
        else => unreachable,
    };
    defer object.deinit(alloc);

    // place contents into output object
    const out = try write(request.target, object, alloc);
    defer alloc.free(out);
    try writeArtifact(request.output_file, out, io);
}

fn write(target: Target, object: Object, alloc: std.mem.Allocator) ![]u8 {
    if (target.host != .X86) return error.UnsupportedArch;

    const text = object.sections.get(.text) orelse {
        return error.MissingTextSection;
    };

    var str_table: ArrayList(u8) = .empty;
    defer str_table.deinit(alloc);
    try str_table.append(alloc, 0);

    var sym_table: ArrayList(u8) = .empty;
    defer sym_table.deinit(alloc);

    // entry zero must be the null symbol
    const null_symbol = std.mem.zeroes(Sym);
    try sym_table.appendSlice(alloc, std.mem.asBytes(&null_symbol));

    for (object.symbols.items) |symbol| {
        // later support more than just main
        if (symbol.binding != .global) continue;

        const name_offset: u32 = @intCast(str_table.items.len);
        try str_table.appendSlice(alloc, symbol.name);
        try str_table.append(alloc, 0);

        const section_kind = symbol.section_kind orelse {
            return error.CantFindLabel;
        };
        const section_index: u16 = switch (section_kind) {
            .text => 1,
            .rodata => return error.UnsupportedSection,
        };

        const elf_symbol: Sym = .{
            .name = name_offset,
            .info = .{
                .bind = .GLOBAL,
                .type = .NOTYPE,
            },
            .other = .{
                .visibility = .DEFAULT,
            },
            .shndx = section_index,
            .value = symbol.offset,
            .size = 0,
        };
        try sym_table.appendSlice(alloc, std.mem.asBytes(&elf_symbol));
    }
    const section_names = "\x00.text\x00.symtab\x00.strtab\x00.shstrtab\x00";
    // store offsets
    const text_name: u32 = 1;
    const symbol_table_name: u32 = 7;
    const str_table_name: u32 = 15;
    const section_header_str_table_name: u32 = 23;
    const string_table_index: u16 = 3;
    const section_header_str_table_index: u16 = 4;
    const section_count: u16 = 5;

    var out = ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    // 0s for elf header type
    // we will fill out later
    try out.appendNTimes(alloc, 0, @sizeOf(Ehdr));

    // .text
    var aligned = std.mem.alignForward(usize, out.items.len, 4);
    try out.appendNTimes(alloc, 0, aligned - out.items.len);
    const text_offset = out.items.len;
    try out.appendSlice(alloc, text.contents.items);
    const text_size = text.contents.items.len;

    // .symtab
    aligned = std.mem.alignForward(usize, out.items.len, 8);
    try out.appendNTimes(alloc, 0, aligned - out.items.len);
    const symbol_offset = out.items.len;
    try out.appendSlice(alloc, sym_table.items);
    const symbol_table_size = sym_table.items.len;

    // .strtab
    const str_table_offset = out.items.len;
    try out.appendSlice(alloc, str_table.items);
    const str_table_size = str_table.items.len;

    // .shstrtab
    const section_header_str_table_offset = out.items.len;
    try out.appendSlice(alloc, section_names);
    const section_header_str_table_size = section_names.len;

    aligned = std.mem.alignForward(usize, out.items.len, 8);
    try out.appendNTimes(alloc, 0, aligned - out.items.len);
    const section_header_offset = out.items.len;

    // null section
    const null_section = std.mem.zeroes(Shdr);
    try out.appendSlice(alloc, std.mem.asBytes(&null_section));

    // .text section
    const text_header: Shdr = .{
        .name = text_name,
        .type = .PROGBITS,
        .flags = .{ .shf = .{
            .ALLOC = true,
            .EXECINSTR = true,
        } },
        .addr = 0,
        .offset = @intCast(text_offset),
        .size = @intCast(text_size),
        .link = 0,
        .info = 0,
        .addralign = 4,
        .entsize = 0,
    };
    try out.appendSlice(alloc, std.mem.asBytes(&text_header));

    // .symtab
    const symtab_header: Shdr = .{
        .name = symbol_table_name,
        .type = .SYMTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = symbol_offset,
        .size = symbol_table_size,
        .link = string_table_index,
        .info = 1,
        .addralign = 8,
        .entsize = @sizeOf(Sym),
    };
    try out.appendSlice(alloc, std.mem.asBytes(&symtab_header));

    // .strtab
    const strtab_header: Shdr = .{
        .name = str_table_name,
        .type = .STRTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = str_table_offset,
        .size = str_table_size,
        .link = 0,
        .info = 0,
        .addralign = 1,
        .entsize = 0,
    };
    try out.appendSlice(alloc, std.mem.asBytes(&strtab_header));

    // .shsstrtab
    const shsstrtab_header: Shdr = .{
        .name = section_header_str_table_name,
        .type = .STRTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = section_header_str_table_offset,
        .size = section_header_str_table_size,
        .link = 0,
        .info = 0,
        .addralign = 1,
        .entsize = 0,
    };
    try out.appendSlice(alloc, std.mem.asBytes(&shsstrtab_header));

    // copy elf header
    var indent = [_]u8{0} ** std.elf.EI.NIDENT;
    @memcpy(indent[0..4], std.elf.MAGIC);
    indent[std.elf.EI.CLASS] = @intFromEnum(std.elf.CLASS.@"64");
    indent[std.elf.EI.DATA] = @intFromEnum(std.elf.DATA.@"2LSB");
    indent[std.elf.EI.VERSION] = 1;
    indent[std.elf.EI.OSABI] = @intFromEnum(std.elf.OSABI.NONE);

    const header: Ehdr = .{
        .ident = indent,
        .type = .REL,
        .machine = .X86_64,
        .version = 1,
        .entry = 0,
        .phoff = 0,
        .shoff = section_header_offset,
        .flags = 0,
        .ehsize = @sizeOf(Ehdr),
        .phentsize = 0,
        .phnum = 0,
        .shentsize = @sizeOf(Shdr),
        .shnum = section_count,
        .shstrndx = section_header_str_table_index,
    };
    @memcpy(out.items[0..@sizeOf(Ehdr)], std.mem.asBytes(&header));

    return try out.toOwnedSlice(alloc);
}

fn writeArtifact(output_file: []const u8, contents: []const u8, io: std.Io) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, output_file, .{});
    var file_buf: [1028]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);

    defer file.close(io);
    try file_writer.interface.writeAll(contents);
    try file_writer.interface.flush();
}
