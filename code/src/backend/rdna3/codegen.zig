const std = @import("std");
const ArrayList = std.ArrayList;

const common = @import("common");
const Operand = common.alloc.Operand;
const Program = common.program.Program;
const TypeInfo = common.types.TypeInfo;
const Block = common.ir.BasicBlock;
const ConstValue = common.ir.ConstValue;
const BasicBlock = common.ir.BasicBlock;
const Function = common.ir.Function;
const ValueRef = common.ir.ValueRef;
const getElementType = common.types.getElementType;
const ColoredGraph = @import("middle").color.ColoredGraph;
const Abi = @import("../gpu_abi.zig").GpuAbi;
const RegisterUsage = @import("../gpu_abi.zig").RegisterUsage;

pub fn emit(
    program: *const Program,
    colors: *const ColoredGraph,
    abi: Abi,
    alloc: std.mem.Allocator,
) ![]u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try emitHeader(&out, alloc);
    for (program.functions.items) |function| {
        if (function.kind == .gpu_kernel) {
            try emitKernelHeader(&out, function.name, alloc);
            for (function.blocks.items) |block| {
                for (block.instructions.items) |instruction| {
                    switch (instruction) {
                        .function_param => |fp| {
                            const dst = try abi.regFor(fp.dst.operand, colors);
                            if (dst.class != .sgpr) return error.InvalidGpuRegisterClass;

                            const kernel_offset = fp.index * 8;
                            try out.print(alloc, "\ts_load_b64 s[{d}:{d}], s[0:1], 0x{d}\n", .{ dst.base, dst.base + 1, kernel_offset });
                            // load is async so place a barrier
                            try out.appendSlice(alloc, "\ts_waitcnt lgkmcnt(0)\n");
                        },
                        .global_idx => |gi| {
                            const dst = try abi.regFor(gi.dst.operand, colors);
                            if (dst.class != .vgpr) return error.InvalidGpuRegisterClass;
                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, v0\n", .{dst.base});
                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst.base + 1});
                        },
                        .lir => |lir| switch (lir) {
                            .move => |m| {
                                const dst = try abi.regFor(m.dst.operand, colors);
                                if (dst.class != .vgpr) return error.InvalidGpuRegisterClass;
                                switch (m.src) {
                                    .constant => |c| switch (c) {
                                        .i64 => |i| {
                                            const bits: u64 = @bitCast(i);
                                            const low: u32 = @truncate(bits);
                                            const high: u32 = @truncate(bits >> 32);

                                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, {d}\n", .{ dst.base, low });
                                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, {d}\n", .{ dst.base + 1, high });
                                        },
                                        else => return error.NotImpl,
                                    },
                                    .top => return error.NotImpl,
                                }
                            },
                            .binop => |bop| {
                                const dst = try abi.regFor(bop.dst.operand, colors);
                                const lhs = try abi.regFor(bop.lhs.operand, colors);
                                const rhs = try abi.regFor(bop.rhs.operand, colors);
                                if (dst.class != .vgpr or lhs.class != .vgpr or rhs.class != .vgpr) return error.InvalidGpuRegisterClass;
                                switch (bop.op) {
                                    .add => {
                                        try out.print(alloc, "\tv_add_u32 v{d}, v{d}, v{d}\n", .{ dst.base, lhs.base, rhs.base });
                                        try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst.base + 1});
                                    },
                                    .mul => {
                                        try out.print(alloc, "\tv_mul_lo_u32 v{d}, v{d}, v{d}\n", .{ dst.base, lhs.base, rhs.base });
                                        try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst.base + 1});
                                    },
                                    else => return error.NotImpl,
                                }
                            },
                            .store_offset => |so| {
                                const base = try abi.regFor(so.dst.operand, colors);
                                const offset = switch (so.offset) {
                                    .constant => return error.NotImpl,
                                    .top => |top| try abi.regFor(top.operand, colors),
                                };
                                const src = try abi.regFor(so.src.operand, colors);
                                if (base.class != .sgpr or offset.class != .vgpr or src.class != .vgpr) return error.InvalidGpuRegisterClass;
                                // *(base + offset) = src
                                try out.print(alloc, "\tglobal_store_b64 v{d}, v[{d}:{d}], s[{d}:{d}]\n", .{
                                    offset.base,
                                    src.base,
                                    src.base + 1,
                                    base.base,
                                    base.base + 1,
                                });
                            },
                            else => |e| {
                                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                return error.NotImpl;
                            },
                        },
                        .function_return => |fr| {
                            if (fr.value != null) return error.UnsupportedGpu;
                            try out.appendSlice(alloc, "\ts_waitcnt vmcnt(0) lgkmcnt(0)\n");
                            try out.appendSlice(alloc, "\ts_endpgm\n");
                        },
                        else => return error.NotImpl,
                    }
                }
            }
            try emitKernelFooter(&out, function.name, alloc);
            const register_usage = try abi.registerUsage(colors);
            try emitKernelDescriptor(&out, function.name, register_usage, alloc);
        }
    }

    // try createFooter(&out, alloc);

    return out.toOwnedSlice(alloc);
}

fn emitHeader(out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, ".amdgcn_target \"amdgcn-amd-amdhsa--gfx1103\"\n");
    try out.appendSlice(alloc, ".amdhsa_code_object_version 6\n");
    try out.appendSlice(alloc, ".text\n");
}

fn emitKernelHeader(out: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    try out.print(alloc, ".protected {s}\n", .{name});
    try out.print(alloc, ".globl {s}\n", .{name});
    try out.appendSlice(alloc, ".p2align 8\n");
    // entry point
    try out.print(alloc, ".type {s},@function\n", .{name});
    try out.print(alloc, "{s}:\n", .{name});
}

fn emitKernelFooter(out: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    // record ELF size
    try out.print(alloc, ".L{s}_end:\n", .{name});
    try out.print(alloc, ".size {s}, .L{s}_end-{s}\n", .{ name, name, name });
}

fn emitKernelDescriptor(
    out: *std.ArrayList(u8),
    name: []const u8,
    register_usage: RegisterUsage,
    alloc: std.mem.Allocator,
) !void {
    try out.appendSlice(alloc, "\t.p2align 6\n");
    try out.print(alloc, ".amdhsa_kernel {s}\n", .{name});
    try out.appendSlice(alloc, "\t.amdhsa_group_segment_fixed_size 0\n");
    try out.appendSlice(alloc, "\t.amdhsa_private_segment_fixed_size 0\n");
    try out.print(alloc, "\t.amdhsa_kernarg_size {d}\n", .{16});
    try out.appendSlice(alloc, "\t.amdhsa_user_sgpr_kernarg_segment_ptr 1\n");
    try out.appendSlice(alloc, "\t.amdhsa_system_sgpr_workgroup_id_x 1\n");
    // we are placing global_idx in v0
    try out.appendSlice(alloc, "\t.amdhsa_system_vgpr_workitem_id 0\n");
    try out.print(alloc, "\t.amdhsa_next_free_vgpr {d}\n", .{register_usage.vgpr_next});
    try out.print(alloc, "\t.amdhsa_next_free_sgpr {d}\n", .{register_usage.sgpr_next});
    try out.appendSlice(alloc, "\t.amdhsa_wavefront_size32 1\n");
    try out.appendSlice(alloc, ".end_amdhsa_kernel\n");
}

test "testing" {}
