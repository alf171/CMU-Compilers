const std = @import("std");
const Object = @import("object.zig");
const SectionKind = @import("object.zig").SectionKind;

pub fn assemble(
    source: []const u8,
    alloc: std.mem.Allocator,
) !Object {
    var object = Object.init();
    errdefer object.deinit(alloc);

    var current_section: ?SectionKind = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\t");
        if (line.len == 0) continue;
        // comment in x86
        if (line[0] == '#') continue;

        // Object.init current creates text
        if (std.mem.eql(u8, line, ".text")) {
            _ = object.getOrCreateSection(.text);
            current_section = .text;
            continue;
        }
        const global_label = ".global ";
        if (std.mem.startsWith(u8, line, global_label)) {
            const name = line[global_label.len..];
            const symbol_index = try object.getOrCreateSymbol(name, alloc);
            object.symbols.items[symbol_index].binding = .global;
            continue;
        }

        if (std.mem.endsWith(u8, line, ":")) {
            const name = std.mem.trim(u8, line[0 .. line.len - 1], "\t");

            const section_kind = current_section orelse return error.NoCurrentSearchIndex;

            const symbol_index = try object.getOrCreateSymbol(name, alloc);
            const symbol = &object.symbols.items[symbol_index];

            const section = object.getOrCreateSection(section_kind);
            symbol.section_kind = section_kind;
            symbol.offset = @intCast(section.contents.items.len);
            continue;
        }
        if (std.mem.startsWith(u8, line, ".asciz")) {
            // TODO: encode Asciz
            continue;
        }
        // emit instruction
        const section_kind = current_section orelse return error.NoCurrentSearchIndex;
        const section = object.getOrCreateSection(section_kind);
        try encodeInstruction(&object, line, &section.contents, alloc);
    }

    resolveFixups(&object);
    return object;
}

// displacement = symbol.offset - (fixup.offset + 4)
// fixup = jmp instruction
// symbol = label we are jumping to
fn resolveFixups(object: *Object) void {
    const text = object.getOrCreateSection(.text);
    for (object.fixups.items) |fixup| {
        const symbol_index: u32 = @intCast(fixup.symbol_index);
        const symbol = &object.symbols.items[symbol_index];
        const offset: u32 = @intCast(fixup.offset);

        const displacement: i64 = symbol.offset - (offset + 4);

        // check displacement is within [min(i32), max(i32)]

        const displacement_bytes = text.contents.items[offset..][0..4];
        std.mem.writeInt(i32, displacement_bytes, @intCast(displacement), .little);
    }
}

fn encodeInstruction(object: *Object, line: []const u8, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if (std.mem.eql(u8, line, "retq")) {
        try out.append(alloc, 0xC3);
        return;
    }
    const push_inst = "pushq ";
    if (std.mem.startsWith(u8, line, push_inst)) {
        const operand = std.mem.trim(u8, line[push_inst.len..], "\t");
        const reg = try Register.parse(operand);
        const id: u8 = @intFromEnum(reg);

        // regs r8-r15 require a rex.b prefix
        if (id >= 8) try out.append(alloc, 0x41);

        // 0x50 is base
        // 0x07 low 3 bits
        try out.append(alloc, 0x50 + (id & 0x07));
        return;
    }
    const mov_inst = "movq ";
    if (std.mem.startsWith(u8, line, mov_inst)) {
        const raw_operands = line[mov_inst.len..];
        const operands = try parseTwoOperands(raw_operands);
        // reg <- reg
        if (operands.dst[0] == '%' and operands.src[0] == '%') {
            const dst = try Register.parse(operands.dst);
            const src = try Register.parse(operands.src);
            _ = dst;
            _ = src;
            return;
        }
        // reg <- value
        else if (operands.dst[0] == '%' and operands.src[0] == '$') {
            return;
        }
    }

    const add_inst = "addq ";
    if (std.mem.startsWith(u8, line, add_inst)) {
        const raw_operands = line[add_inst.len..];
        const operands = try parseTwoOperands(raw_operands);
        // reg <- reg
        if (operands.dst[0] == '%' and operands.src[0] == '%') {
            const src = try Register.parse(operands.src);
            const dst = try Register.parse(operands.dst);
            _ = src;
            _ = dst;
            return;
        }
        // reg <- value
        else if (operands.dst[0] == '%' and operands.src[0] == '$') {
            return;
        }
    }

    const sub_inst = "subq ";
    if (std.mem.startsWith(u8, line, sub_inst)) {
        const raw_operands = line[sub_inst.len..];
        const operands = try parseTwoOperands(raw_operands);
        // reg <- reg
        if (operands.dst[0] == '%' and operands.src[0] == '%') {
            const src = try Register.parse(operands.src);
            const dst = try Register.parse(operands.dst);
            _ = src;
            _ = dst;
            return;
        }
        // reg <- value
        else if (operands.dst[0] == '%' and operands.src[0] == '$') {
            return;
        }
    }

    const jmp_inst = "jmp ";
    if (std.mem.startsWith(u8, line, jmp_inst)) {
        const target_name = line[jmp_inst.len..];
        const symbol_index = try object.getOrCreateSymbol(target_name, alloc);

        // op code for jmp
        try out.append(alloc, 0xE9);

        const displacement_offset: u32 = @intCast(out.items.len);
        try out.appendSlice(alloc, &.{ 0, 0, 0, 0 });
        try object.fixups.append(alloc, .{
            .offset = displacement_offset,
            .symbol_index = symbol_index,
            .section = .text,
        });
        return;
    }

    const pop_inst = "popq ";
    if (std.mem.startsWith(u8, line, pop_inst)) {
        const operands = line[pop_inst.len..];
        const reg = try Register.parse(operands);
        const id: u8 = @intFromEnum(reg);
        // regs r8-r15 require a rex.b prefix
        if (id >= 8) try out.append(alloc, 0x41);

        // 0x58 = pop, rest is reg bits
        try out.append(alloc, 0x58 + (id & 0x7));
        return;
    }
    std.debug.print("unsupported x86 instruction {s}\n", .{line});
    return error.UnsupportedInstruction;
}

fn parseTwoOperands(operands: []const u8) !struct {
    dst: []const u8,
    src: []const u8,
} {
    const comma = std.mem.indexOf(u8, operands, ",") orelse return error.InvalidOperands;
    const src_text = operands[0..comma];
    const dst_text = std.mem.trim(u8, operands[comma + 1 ..], " ");
    return .{
        .dst = dst_text,
        .src = src_text,
    };
}

const Register = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub fn parse(operand: []const u8) !@This() {
        // std.debug.print("parsing {s}\n", .{operand});
        if (operand.len < 2 or operand[0] != '%')
            return error.InvalidRegister;

        return std.meta.stringToEnum(@This(), operand[1..]) orelse return error.CantFindRegister;
    }
};
