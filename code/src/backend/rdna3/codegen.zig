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
                            if (dst.reg_type != .sgpr) return error.InvalidGpuRegisterClass;

                            const kernel_offset = fp.index * 8;
                            switch (dst.width) {
                                1 => {
                                    try out.print(alloc, "\ts_load_b32 s{d}, s[0:1], {d}\n", .{ dst.base, kernel_offset });
                                },
                                2 => {
                                    try out.print(alloc, "\ts_load_b64 s[{d}:{d}], s[0:1], {d}\n", .{ dst.base, dst.base + 1, kernel_offset });
                                },
                                else => return error.NotImpl,
                            }
                            // load is async so place a barrier
                            try out.appendSlice(alloc, "\ts_waitcnt lgkmcnt(0)\n");
                        },
                        .global_idx => |gi| {
                            const dst = try abi.regFor(gi.dst.operand, colors);
                            if (dst.reg_type != .vgpr) return error.InvalidGpuRegisterClass;
                            switch (gi.axis) {
                                .constant => |c| {
                                    const axis = try c.valueAsIntImm();
                                    const bit_offset: u8 = @intCast(axis * 10);
                                    // bit field extract work item asked for
                                    // x=0 (bits 0-9), y=1 (bits 10-19), z=2 (bits 20-29)
                                    try out.print(alloc, "\tv_bfe_u32 v{d}, v0, {d}, {d}\n", .{ dst.base, bit_offset, 10 });
                                    if (dst.width == 2)
                                        try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst.base + 1});
                                },
                                else => |e| {
                                    std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                    return error.NotImpl;
                                },
                            }
                        },
                        .lir => |lir| switch (lir) {
                            .move => |m| {
                                const dst = try abi.regFor(m.dst.operand, colors);
                                if (dst.reg_type != .vgpr) return error.InvalidGpuRegisterClass;
                                switch (m.src) {
                                    .constant => |c| switch (c) {
                                        .i64 => |i| {
                                            std.debug.assert(dst.width == 2);
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
                                if (dst.reg_type != .vgpr or lhs.reg_type != .vgpr or rhs.reg_type != .vgpr) return error.InvalidGpuRegisterClass;
                                switch (bop.op) {
                                    .add => {
                                        try out.print(alloc, "\tv_add_u32 v{d}, v{d}, v{d}\n", .{ dst.base, lhs.base, rhs.base });
                                        if (dst.width == 2)
                                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst.base + 1});
                                    },
                                    .mul => {
                                        try out.print(alloc, "\tv_mul_lo_u32 v{d}, v{d}, v{d}\n", .{ dst.base, lhs.base, rhs.base });
                                        if (dst.width == 2)
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
                                switch (base.reg_type) {
                                    .sgpr => {
                                        // *(base + offset) = src
                                        switch (so.src.type) {
                                            .i64, .list => {
                                                try out.print(alloc, "\tglobal_store_b64 v{d}, v[{d}:{d}], s[{d}:{d}]\n", .{
                                                    offset.base,
                                                    src.base,
                                                    src.base + 1,
                                                    base.base,
                                                    base.base + 1,
                                                });
                                            },
                                            .i32 => {
                                                try out.print(alloc, "\tglobal_store_b32 v{d}, v{d}, s[{d}:{d}]\n", .{
                                                    offset.base,
                                                    src.base,
                                                    base.base,
                                                    base.base + 1,
                                                });
                                            },
                                            else => |e| {
                                                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                                return error.NotImpl;
                                            },
                                        }
                                    },
                                    .vgpr => {
                                        std.debug.assert(base.width == 2);
                                        std.debug.assert(offset.width == 2);
                                        std.debug.assert(src.width == 2);
                                        // *(base + offset) = src
                                        // address = base + offset
                                        const address = try abi.scratchReg(0, 2, .vgpr);
                                        try out.print(alloc, "\tv_add_co_u32 v{d}, vcc_lo, v{d}, v{d}\n", .{
                                            address.base,
                                            base.base,
                                            offset.base,
                                        });
                                        try out.print(alloc, "\tv_add_co_ci_u32 v{d}, vcc_lo, v{d}, v{d}, vcc_lo\n", .{
                                            address.base + 1,
                                            base.base + 1,
                                            offset.base + 1,
                                        });
                                        // address = src
                                        switch (so.src.type) {
                                            .i32 => {
                                                try out.print(alloc, "\tglobal_store_b32 v[{d}:{d}], v{d}, off\n", .{
                                                    address.base,
                                                    address.base + 1,
                                                    src.base,
                                                });
                                            },
                                            else => |e| {
                                                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                                return error.NotImpl;
                                            },
                                        }
                                    },
                                    else => return error.UnexpectedRegisterType,
                                }
                            },
                            .load_offset => |lo| {
                                const dst = try abi.regFor(lo.dst.operand, colors);
                                const offset = switch (lo.offset) {
                                    .constant => return error.NotImpl,
                                    .top => |top| try abi.regFor(top.operand, colors),
                                };
                                const src = try abi.regFor(lo.src.operand, colors);
                                if (dst.reg_type != .vgpr or offset.reg_type != .vgpr or src.reg_type != .sgpr) return error.InvalidGpuRegisterClass;
                                // dst = *(src + offset)
                                switch (lo.dst.type) {
                                    .i64, .list => {
                                        try out.print(alloc, "\tglobal_load_b64 v[{d}:{d}], v{d}, s[{d}:{d}]\n", .{
                                            dst.base,
                                            dst.base + 1,
                                            offset.base,
                                            src.base,
                                            src.base + 1,
                                        });
                                        try out.appendSlice(alloc, "\ts_waitcnt vmcnt(0)\n");
                                    },
                                    .i32 => {
                                        std.debug.assert(dst.width == 1);
                                        std.debug.assert(src.width == 2);
                                        try out.print(alloc, "\tglobal_load_b32 v{d}, v{d}, s[{d}:{d}]\n", .{
                                            dst.base,
                                            offset.base,
                                            src.base,
                                            src.base + 1,
                                        });
                                        try out.appendSlice(alloc, "\ts_waitcnt vmcnt(0)\n");
                                    },
                                    else => |e| {
                                        std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                        return error.NotImpl;
                                    },
                                }
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
            try emitKernelDescriptor(&out, function.name, register_usage, function.params.len, alloc);
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
    kernel_param_count: usize,
    alloc: std.mem.Allocator,
) !void {
    try out.appendSlice(alloc, "\t.p2align 6\n");
    try out.print(alloc, ".amdhsa_kernel {s}\n", .{name});
    try out.appendSlice(alloc, "\t.amdhsa_group_segment_fixed_size 0\n");
    try out.appendSlice(alloc, "\t.amdhsa_private_segment_fixed_size 0\n");
    try out.print(alloc, "\t.amdhsa_kernarg_size {d}\n", .{kernel_param_count * 8});
    try out.appendSlice(alloc, "\t.amdhsa_user_sgpr_kernarg_segment_ptr 1\n");
    try out.appendSlice(alloc, "\t.amdhsa_system_sgpr_workgroup_id_x 1\n");
    // FIXME: we should avoid hardcoding here
    try out.appendSlice(alloc, "\t.amdhsa_system_vgpr_workitem_id 2\n");
    try out.print(alloc, "\t.amdhsa_next_free_vgpr {d}\n", .{register_usage.vgpr_next});
    try out.print(alloc, "\t.amdhsa_next_free_sgpr {d}\n", .{register_usage.sgpr_next});
    try out.appendSlice(alloc, "\t.amdhsa_wavefront_size32 1\n");
    try out.appendSlice(alloc, ".end_amdhsa_kernel\n");
}

test "testing" {}
